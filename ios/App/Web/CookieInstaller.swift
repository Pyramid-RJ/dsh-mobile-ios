import Foundation
import WebKit
import DSHTransport

/// Installs the session cookies and only then lets the caller load the page.
///
/// __Host- cookies require Secure + Path=/ + no Domain attribute; HTTPCookie
/// takes the host as domain and WebKit treats it as host-only (docs/02 section 4.4).
enum CookieInstaller {
    static func install(_ planned: [PlannedCookie], into store: WKWebsiteDataStore) async {
        let cookies: [HTTPCookie] = planned.compactMap { cookie in
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name,
                .value: cookie.value,
                .domain: cookie.domain,
                .path: cookie.path,
                .secure: "TRUE",
                .expires: cookie.expires,
            ]
            return HTTPCookie(properties: properties)
        }
        guard !cookies.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookies(cookies) {
                continuation.resume()
            }
        }
    }
}
