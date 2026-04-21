#if os(macOS)
import Foundation
import Security
import X509
import Crypto

enum TLSIdentity {
    struct Identity {
        let secIdentity: sec_identity_t
    }

    static func selfSigned() throws -> Identity {
        // Generate key via CryptoKit; store in keychain via SecItem so SecIdentityCreate can pair it
        let privateKey = P256.Signing.PrivateKey()

        // Import private key into keychain
        let keyAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: "dev.airpdf.quic.key",
        ]
        // Remove any stale entry first
        SecItemDelete([kSecClass: kSecClassKey,
                       kSecAttrApplicationTag: "dev.airpdf.quic.key"] as CFDictionary)

        var cfError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            privateKey.x963Representation as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
             kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary,
            &cfError
        ) else {
            throw cfError!.takeRetainedValue()
        }

        let addKeyQuery: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrApplicationTag: "dev.airpdf.quic.key",
            kSecAttrIsPermanent: true,
        ]
        SecItemAdd(addKeyQuery as CFDictionary, nil)

        // Build cert using swift-certificates
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(privateKey.publicKey),
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 3600),
            issuer: DistinguishedName { CommonName("AirPDF") },
            subject: DistinguishedName { CommonName("AirPDF") },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: .init(privateKey)
        )
        let secCert = try SecCertificate.makeWithCertificate(cert)

        // Store cert in keychain
        SecItemDelete([kSecClass: kSecClassCertificate,
                       kSecValueRef: secCert] as CFDictionary)
        SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCert] as CFDictionary, nil)

        guard let identity = SecIdentityCreate(nil, secCert, secKey),
              let secId = sec_identity_create(identity) else {
            throw CocoaError(.fileReadUnknown)
        }
        return Identity(secIdentity: secId)
    }
}
#endif
