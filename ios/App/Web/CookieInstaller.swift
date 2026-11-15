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
    /// Installs the cookies, giving up on each one after `timeout` seconds.
    ///
    /// `setCookie` has no timeout of its own, and a cookie store that never
    /// calls back used to leave the page unloaded - a blank web view with no
    /// error anywhere. A page without its session cookie is recoverable (the
    /// page renews through the bridge); a page that never loads is not.
    static func install(
        _ planned: [PlannedCookie],
        into store: WKWebsiteDataStore,
        timeout: TimeInterval = 3
    ) async {
        let cookieStore = store.httpCookieStore
        var installed = 0

        for cookie in planned {
            guard let httpCookie = makeCookie(cookie) else { continue }
            let done = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let guardBox = ResumeOnce(continuation)
                cookieStore.setCookie(httpCookie) {
                    guardBox.resume(true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    guardBox.resume(false)
                }
            }
            if done { installed += 1 }
        }

        if installed != planned.count {
            Task { @MainActor in
                BridgeLog.shared.append(
                    "cookies",
                    detail: "installed \(installed)/\(planned.count) (some timed out)"
                )
            }
        }
    }

    /// Resumes a continuation at most once, whichever side wins the race.
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    /// Removes every cookie and the cached site data for one host.
    ///
    /// Deleting a device record has to leave nothing behind: a stale session
    /// cookie would let the next page load look authenticated (docs/01 F-4.4).
    static func remove(host: String, from store: WKWebsiteDataStore = .default()) async {
        let cookieStore = store.httpCookieStore
        let cookies = await allCookies(from: cookieStore)
        for cookie in cookies where cookie.domain.hasSuffix(host) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.delete(cookie) { continuation.resume() }
            }
        }

        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await allRecords(of: types, in: store)
        let matching = records.filter { record in
            record.displayName.caseInsensitiveCompare(host) == .orderedSame
                || record.displayName.hasSuffix("." + host)
        }
        guard !matching.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, for: matching) { continuation.resume() }
        }
    }

    /// Removes everything this app stored in the web view.
    static func removeAll(from store: WKWebsiteDataStore = .default()) async {
        let cookieStore = store.httpCookieStore
        for cookie in await allCookies(from: cookieStore) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.delete(cookie) { continuation.resume() }
            }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
        }
    }

    private static func allCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func allRecords(
        of types: Set<String>,
        in store: WKWebsiteDataStore
    ) async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
            store.fetchDataRecords(ofTypes: types) { records in
                continuation.resume(returning: records)
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
