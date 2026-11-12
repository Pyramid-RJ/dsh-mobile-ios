import Foundation
import Security

/// URLSession delegate that accepts only server certificates chaining to the
/// pinned CA. Other authentication methods keep the system default behaviour.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    private let evaluator: PinnedTrustEvaluator
    /// Last decision per host, for the diagnostics screen.
    public private(set) var decisions: [String: TrustDecision] = [:]

    public init(evaluator: PinnedTrustEvaluator) {
        self.evaluator = evaluator
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let decision = evaluator.evaluate(trust, host: host)
        decisions[host] = decision

        switch decision {
        case .allowed:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .rejected:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// UNSAFE BY DESIGN. Only for the documented bootstrap window: fetching
/// /mobile-access/ca.cer (and /discovery) before any CA is pinned, because at
/// that moment there is nothing to pin against yet. Callers must restrict this
/// delegate to those paths and stop using it afterwards (docs/04 section 2.3).
public final class BootstrapOnlyTrustDelegate: NSObject, URLSessionDelegate {
    /// Hosts whose certificate was accepted without verification, for logging.
    public private(set) var acceptedHosts: [String] = []

    public override init() {
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        acceptedHosts.append(challenge.protectionSpace.host)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
