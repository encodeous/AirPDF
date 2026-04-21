import Foundation
import Security
import CryptoKit

/// SHA-256 fingerprint of a TLS certificate's DER bytes (first 8 hex chars).
///
/// Usage:
/// - Mac server: `TLSFingerprint.of(identity.certificate)` — own fingerprint
/// - Mac server: reads peer (iPad) cert from `sec_protocol_metadata_access_peer_certificate_chain`
/// - iPad client: `TLSFingerprint.of(identity.certificate)` — own fingerprint
/// - iPad client: reads server (Mac) cert from `SecTrustGetCertificateAtIndex(trust, 0)`
enum TLSFingerprint {
    static func of(_ certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
