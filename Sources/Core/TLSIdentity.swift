import Foundation
import Security
import X509
import Crypto
import CryptoKit

/// Generates an ephemeral self-signed TLS identity (key + certificate).
/// A new identity is created each launch — no persistence.
enum TLSIdentity {
    struct Identity {
        let secIdentity: sec_identity_t
        let certificate: SecCertificate
    }

    static func ephemeral() throws -> Identity {
        let privateKey = P256.Signing.PrivateKey()
        let tag = "dev.airpdf.quic.key.\(UUID().uuidString)"

        var cfError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            privateKey.x963Representation as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
             kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary,
            &cfError
        ) else { throw cfError!.takeRetainedValue() }

        // Store key ephemerally in keychain so SecIdentityCreate can pair it
        SecItemDelete([kSecClass: kSecClassKey,
                       kSecAttrApplicationTag: tag] as CFDictionary)
        SecItemAdd([kSecClass: kSecClassKey,
                    kSecValueRef: secKey,
                    kSecAttrApplicationTag: tag,
                    kSecAttrIsPermanent: true] as CFDictionary, nil)

        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(privateKey.publicKey),
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(24 * 3600),
            issuer: DistinguishedName { CommonName("AirPDF") },
            subject: DistinguishedName { CommonName("AirPDF") },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: .init(privateKey)
        )
        let secCert = try SecCertificate.makeWithCertificate(cert)

        SecItemDelete([kSecClass: kSecClassCertificate, kSecValueRef: secCert] as CFDictionary)
        SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCert] as CFDictionary, nil)

        guard let identity = SecIdentityCreate(nil, secCert, secKey),
              let secId = sec_identity_create(identity) else {
            throw CocoaError(.fileReadUnknown)
        }
        return Identity(secIdentity: secId, certificate: secCert)
    }
}
