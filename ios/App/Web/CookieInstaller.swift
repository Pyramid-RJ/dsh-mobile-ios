import Foundation
import WebKit
import DSHTransport

/// Installs the session cookies and only then lets the caller load the page.
///
/// __Host- cookies require Secure + Path=/ + no Domain attribute; HTTPCookie
/// takes the host as domain and WebKit treats it as host-only (docs/02 section 4.4).
/// WKHTTPCookieStore only offers setCookie(_:completionHandler:) per cookie, so
/// they are installed one at a time and every completion is awaited.
enum CookieInstaller {
    static func install(_ planned: [PlannedCookie], into store: WKWebsiteDataStore) async {
        let cookieStore = store.httpCookieStore

        for cookie in planned {
            guard let httpCookie = makeCookie(cookie) else { continue }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.setCookie(httpCookie) {
                    continuation.resume()
                }
            }
        }
    }

    private static func makeCookie(_ cookie: PlannedCookie) -> HTTPCookie? {
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
}
