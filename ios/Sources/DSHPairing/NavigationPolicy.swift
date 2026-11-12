import Foundation

/// What the shell should do with a navigation request.
public enum NavigationDecision: Equatable, Sendable {
    /// Load it in the web view.
    case allow
    /// Hand it to the system browser (Safari).
    case openInBrowser
    /// Refuse it.
    case block
}

/// The navigation rules from the architecture document, as pure logic so they
/// can be tested without a web view.
///
/// - main frame, exact origin: allow
/// - main frame, other https: hand to the system browser
/// - main frame, anything else: block
/// - subframe, exact origin only: anything else is blocked
public struct NavigationPolicy: Sendable {
    public let origin: GatewayOrigin

    public init(origin: GatewayOrigin) {
        self.origin = origin
    }

    public func decideForMainFrame(_ url: URL) -> NavigationDecision {
        guard let candidate = GatewayOrigin(url: url) else { return .block }
        if candidate == origin { return .allow }
        return candidate.scheme == "https" ? .openInBrowser : .block
    }

    public func decideForSubframe(_ url: URL) -> NavigationDecision {
        guard let candidate = GatewayOrigin(url: url) else { return .block }
        return candidate == origin ? .allow : .block
    }
}

extension GatewayOrigin {
    /// Builds an origin from a URL, rejecting anything without scheme or host.
    init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else {
            return nil
        }
        guard let origin = try? GatewayOrigin(scheme: scheme, host: host, port: url.port) else {
            return nil
        }
        self = origin
    }
}
