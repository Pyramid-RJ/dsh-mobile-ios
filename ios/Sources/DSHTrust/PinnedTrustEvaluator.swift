import Foundation
import Security

/// Why a server trust was refused.
public enum TrustFailure: Equatable, CustomStringConvertible {
    /// No certificate authority was pinned yet.
    case noAnchors
    /// Installing the anchor list or the SSL policy failed.
    case setupFailed(Int32)
    /// Evaluation ran and the system said no.
    case evaluationFailed(String)

    public var description: String {
        switch self {
        case .noAnchors:
            return "no pinned certificate authority"
        case .setupFailed(let status):
            return "trust setup failed with OSStatus " + String(status)
        case .evaluationFailed(let message):
            return "trust evaluation failed: " + message
        }
    }
}

public enum TrustDecision: Equatable {
    case allowed
    case rejected(TrustFailure)
}

/// Evaluates a server trust against a pinned CA.
///
/// This is the single place allowed to answer a TLS challenge for server trust.
/// Keeping it in one type is what makes the "pin exactly one CA" rule
/// auditable: no other module may call useCredential for server trust
/// (docs/02 section 1).
public struct PinnedTrustEvaluator {
    public let anchors: [SecCertificate]

    public init(anchors: [SecCertificate]) {
        self.anchors = anchors
    }

    public init(certificateAuthorities: [CertificateAuthority]) {
        self.anchors = certificateAuthorities.map { $0.certificate }
    }

    public init(certificateAuthority: CertificateAuthority) {
        self.init(certificateAuthorities: [certificateAuthority])
    }

    /// - Parameter host: pass the gateway host so the policy also checks the
    ///   leaf certificate against it. Pass nil only where hostname checking is
    ///   done elsewhere (bootstrap) or not meaningful (tests).
    public func evaluate(_ trust: SecTrust, host: String?) -> TrustDecision {
        guard !anchors.isEmpty else { return .rejected(.noAnchors) }

        let anchorStatus = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        guard anchorStatus == errSecSuccess else {
            return .rejected(.setupFailed(anchorStatus))
        }
        SecTrustSetAnchorCertificatesOnly(trust, true)

        let policyHost: CFString? = host.map { $0 as CFString }
        let policy = SecPolicyCreateSSL(true, policyHost)
        let policyStatus = SecTrustSetPolicies(trust, [policy] as CFArray)
        guard policyStatus == errSecSuccess else {
            return .rejected(.setupFailed(policyStatus))
        }

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return .allowed
        }

        var message = "unknown trust error"
        if let error {
            message = (CFErrorCopyDescription(error) as String?) ?? message
        }
        return .rejected(.evaluationFailed(message))
    }
}
