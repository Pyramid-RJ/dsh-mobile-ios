import Foundation
import DSHPairing

/// A cookie the app has to install before loading the gateway page.
///
/// Kept as data rather than an HTTPCookie so the naming rules are testable
/// without WebKit; the app turns these into HTTPCookie instances.
public struct PlannedCookie: Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let secure: Bool
    public let expires: Date

    public init(name: String, value: String, domain: String, path: String, secure: Bool, expires: Date) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.expires = expires
    }
}

/// Builds the two session cookies from a renewal result (docs/02 section 4.4).
///
/// The __Host- prefix requires Secure, Path=/ and no Domain attribute; the app
/// therefore sets the host as the cookie domain, which WebKit treats as a
/// host-only cookie. SameSite=Strict cannot be expressed through HTTPCookie and
/// degrades to Lax — a known, documented deviation (docs/04 section 7).
public enum SessionCookiePlan {
    public static let sessionName = "__Host-dsh_ma_session"
    public static let csrfName = "__Host-dsh_ma_csrf"

    public static func cookies(for origin: GatewayOrigin, session: SessionCredential) -> [PlannedCookie] {
        let expires = session.sessionExpiresAt
        return [
            PlannedCookie(
                name: sessionName,
                value: session.sessionToken,
                domain: origin.host,
                path: "/",
                secure: true,
                expires: expires
            ),
            PlannedCookie(
                name: csrfName,
                value: session.csrfToken,
                domain: origin.host,
                path: "/",
                secure: true,
                expires: expires
            ),
        ]
    }
}
