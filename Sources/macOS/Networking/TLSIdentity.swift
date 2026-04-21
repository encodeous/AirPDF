#if os(macOS)
import Foundation
import Security

/// Generates or retrieves a self-signed TLS identity for the QUIC server.
/// Stored in the keychain so it persists across launches (avoids regenerating on every start).
enum TLSIdentity {
    private static let keychainLabel = "dev.airpdf.mac.quic-identity"

    struct Identity {
        let secIdentity: sec_identity_t
    }

    static func selfSigned() throws -> Identity {
        if let existing = try? loadFromKeychain() {
            return existing
        }
        return try generateAndStore()
    }

    // MARK: - Private

    private static func loadFromKeychain() throws -> Identity {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: keychainLabel,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, result != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        // swiftlint:disable:next force_cast
        let secId = sec_identity_create(result as! SecIdentity)!
        return Identity(secIdentity: secId)
    }

    private static func generateAndStore() throws -> Identity {
        // Key pair
        let keyAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CocoaError(.fileReadUnknown)
        }

        // Build a minimal self-signed X.509 certificate using ASN.1 DER encoding.
        let certData = try generateSelfSignedCertDER(publicKey: publicKey, privateKey: privateKey)
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Store in keychain
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: keychainLabel,
            kSecValueRef: cert,
        ]
        SecItemDelete(addQuery as CFDictionary)
        SecItemAdd(addQuery as CFDictionary, nil)

        guard let identity = SecIdentityCreate(nil, cert, privateKey) else {
            throw CocoaError(.fileReadUnknown)
        }
        let secId = sec_identity_create(identity)!
        return Identity(secIdentity: secId)
    }

    /// Generates a minimal self-signed DER certificate using CryptoKit + ASN.1 encoding.
    private static func generateSelfSignedCertDER(publicKey: SecKey, privateKey: SecKey) throws -> Data {
        // Extract public key DER
        var error: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error!.takeRetainedValue()
        }

        // Build a minimal self-signed X.509 cert (DER)
        // This is a simplified structure sufficient for local QUIC TLS.
        // Fields: version=2, serial=1, algo=sha256WithRSAEncryption, subject/issuer=CN=AirPDF,
        //         validity=10 years, subjectPublicKeyInfo=RSA pubkey
        let now = Date()
        let expiry = now.addingTimeInterval(10 * 365 * 24 * 3600)
        let tbsCert = try buildTBSCertificate(pubKeyData: pubKeyData, notBefore: now, notAfter: expiry)

        // Sign TBSCertificate with private key
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw CocoaError(.fileReadUnknown)
        }
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, tbsCert as CFData, &error) as Data? else {
            throw error!.takeRetainedValue()
        }

        // Wrap into Certificate SEQUENCE
        let sigAlgoSeq = asn1Sequence([
            asn1OID([1, 2, 840, 113549, 1, 1, 11]), // sha256WithRSAEncryption
            asn1Null(),
        ])
        let sigBitString = asn1BitString(signature)
        return asn1Sequence([tbsCert, sigAlgoSeq, sigBitString])
    }

    private static func buildTBSCertificate(pubKeyData: Data, notBefore: Date, notAfter: Date) throws -> Data {
        let version = asn1ContextTag(0, explicit: true, content: asn1Integer(Data([2]))) // v3
        let serial = asn1Integer(Data([1]))
        let sigAlgo = asn1Sequence([
            asn1OID([1, 2, 840, 113549, 1, 1, 11]),
            asn1Null(),
        ])
        let name = asn1Sequence([
            asn1Set([
                asn1Sequence([
                    asn1OID([2, 5, 4, 3]), // commonName
                    asn1UTF8String("AirPDF"),
                ]),
            ]),
        ])
        let validity = asn1Sequence([
            asn1UTCTime(notBefore),
            asn1UTCTime(notAfter),
        ])
        // RSA SubjectPublicKeyInfo
        let spki = asn1Sequence([
            asn1Sequence([asn1OID([1, 2, 840, 113549, 1, 1, 1]), asn1Null()]),
            asn1BitString(pubKeyData),
        ])
        return asn1Sequence([version, serial, sigAlgo, name, validity, name, spki])
    }

    // MARK: - Minimal ASN.1 DER helpers

    private static func asn1Length(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        } else if length <= 0xFF {
            return Data([0x81, UInt8(length)])
        } else {
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        }
    }

    private static func asn1TLV(tag: UInt8, content: Data) -> Data {
        Data([tag]) + asn1Length(content.count) + content
    }

    private static func asn1Sequence(_ items: [Data]) -> Data {
        asn1TLV(tag: 0x30, content: items.reduce(Data(), +))
    }

    private static func asn1Set(_ items: [Data]) -> Data {
        asn1TLV(tag: 0x31, content: items.reduce(Data(), +))
    }

    private static func asn1Integer(_ value: Data) -> Data {
        // Prepend 0x00 if high bit set (to keep positive)
        let padded = (value.first ?? 0) >= 0x80 ? Data([0x00]) + value : value
        return asn1TLV(tag: 0x02, content: padded)
    }

    private static func asn1OID(_ components: [Int]) -> Data {
        var body = Data()
        body.append(UInt8(components[0] * 40 + components[1]))
        for c in components.dropFirst(2) {
            var val = c
            var bytes: [UInt8] = []
            bytes.append(UInt8(val & 0x7F))
            val >>= 7
            while val > 0 {
                bytes.append(UInt8((val & 0x7F) | 0x80))
                val >>= 7
            }
            body.append(contentsOf: bytes.reversed())
        }
        return asn1TLV(tag: 0x06, content: body)
    }

    private static func asn1Null() -> Data { Data([0x05, 0x00]) }

    private static func asn1UTF8String(_ s: String) -> Data {
        asn1TLV(tag: 0x0C, content: Data(s.utf8))
    }

    private static func asn1BitString(_ data: Data) -> Data {
        asn1TLV(tag: 0x03, content: Data([0x00]) + data) // 0 unused bits
    }

    private static func asn1UTCTime(_ date: Date) -> Data {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMddHHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return asn1TLV(tag: 0x17, content: Data(fmt.string(from: date).utf8))
    }

    private static func asn1ContextTag(_ tag: UInt8, explicit: Bool, content: Data) -> Data {
        let t: UInt8 = 0xA0 | tag
        return explicit ? asn1TLV(tag: t, content: content) : Data([t]) + asn1Length(content.count) + content
    }
}
#endif
