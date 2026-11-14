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
    /// The pinned CA itself is past its validity window.
    case anchorExpired

    public var description: String {
        switch self {
        case .noAnchors:
            return "no pinned certificate authority"
        case .setupFailed(let status):
            return "trust setup failed with OSStatus " + String(status)
        case .evaluationFailed(let message):
            return "trust evaluation failed: " + message
        case .anchorExpired:
            return "CA 已过期，请重新配对"
        }
    }
}

public enum TrustDecision: Equatable {
    case allowed
    case rejected(TrustFailure)
}

/// Anything that can answer a server-trust challenge.
///
/// Two implementations exist on purpose: the pinned evaluator for gateways that
/// serve a private CA, and the system evaluator for gateways behind a public
/// certificate (a tunnel). Which one a record uses is decided at pairing time and
/// stored with the record (docs/04 section 2).
public protocol GatewayTrustEvaluating: Sendable {
    func evaluate(_ trust: SecTrust, host: String?) -> TrustDecision
}

/// Accepts whatever the system already trusts.
///
/// Only for gateways that answered 404 at `/mobile-access/ca.cer`, i.e. a public
/// certificate from a real CA. A pairing link that requires pinning (`dsh2.`)
/// must never end up here.
public struct SystemTrustEvaluator: GatewayTrustEvaluating {
    public init() {}

    public func evaluate(_ trust: SecTrust, host: String?) -> TrustDecision {
        let policyHost: CFString? = host.map { $0 as CFString }
        let policy = SecPolicyCreateSSL(true, policyHost)
        let status = SecTrustSetPolicies(trust, [policy] as CFArray)
        guard status == errSecSuccess else {
            return .rejected(.setupFailed(status))
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

/// Evaluates a server trust against a pinned CA.
///
/// This is the single place allowed to answer a TLS challenge for server trust.
/// Keeping it in one type is what makes the "pin exactly one CA" rule
/// auditable: no other module may call useCredential for server trust
/// (docs/02 section 1).
public struct PinnedTrustEvaluator: GatewayTrustEvaluating {
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

        // An expired CA has to say so: "TLS failed" sends the user looking at
        // the network instead of re-pairing (docs/04 section 2).
        if Self.anyAnchorExpired(anchors) {
            return .rejected(.anchorExpired)
        }

        var message = "unknown trust error"
        if let error {
            message = (CFErrorCopyDescription(error) as String?) ?? message
        }
        return .rejected(.evaluationFailed(message))
    }

    /// Whether any pinned certificate is past `notAfter`.
    static func anyAnchorExpired(_ certificates: [SecCertificate], now: Date = Date()) -> Bool {
        for certificate in certificates {
            guard let values = SecCertificateCopyValues(
                certificate,
                [kSecOIDX509V1ValidityNotAfter] as CFArray,
                nil
            ) as? [CFString: Any],
                let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
                let value = entry[kSecPropertyKeyValue] as? NSNumber else {
                continue
            }
            let expiry = Date(timeIntervalSinceReferenceDate: value.doubleValue)
            if expiry < now {
                return true
            }
        }
        return false
    }
}
