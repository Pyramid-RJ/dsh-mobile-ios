import Foundation
import CryptoKit
import Security

/// A certificate authority pinned for one gateway.
///
/// The instanceId of a pairing key is the SHA-256 of this certificate's DER
/// encoding, so "the digest of the CA we fetched equals the instanceId" is the
/// whole pinning check. See docs/04 section 2.
public struct CertificateAuthority {
    public let der: Data
    public let certificate: SecCertificate

    /// Fails when the bytes are not a certificate the system can parse.
    public init?(der: Data) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return nil
        }
        self.der = der
        self.certificate = certificate
    }

    /// Accepts a PEM block (the -----BEGIN CERTIFICATE----- form).
    public init?(pem: String) {
        guard let der = CertificateAuthority.der(fromPEM: pem) else { return nil }
        self.init(der: der)
    }

    /// Accepts DER bytes or a PEM document, which is what both the gateway and
    /// a pasted clipboard entry can produce.
    public static func parse(_ data: Data) -> CertificateAuthority? {
        if let authority = CertificateAuthority(der: data) {
            return authority
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return CertificateAuthority(pem: text)
    }

    public static func parse(base64: String) -> CertificateAuthority? {
        let cleaned = base64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return CertificateAuthority(der: data)
    }

    /// Lowercase hex SHA-256 of the DER encoding, as used for instanceId.
    public var sha256Hex: String {
        CertificateAuthority.fingerprint(der)
    }

    public func matches(instanceId: String) -> Bool {
        let normalized = instanceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return sha256Hex == normalized
    }

    public var subjectSummary: String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? "unknown"
    }

    public static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func der(fromPEM text: String) -> Data? {
        let body = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body)
    }
}
