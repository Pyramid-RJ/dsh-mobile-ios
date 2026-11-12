import SwiftUI
import WebKit
import DSHPairing
import DSHTrust

struct GatewayWebViewScreen: View {
    let session: BrowserSession

    var body: some View {
        GatewayWebView(session: session)
            .navigationTitle(session.origin.host)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Loads the gateway with the pinned CA, after the session cookies are in place.
struct GatewayWebView: UIViewRepresentable {
    let session: BrowserSession

    func makeCoordinator() -> Coordinator {
        Coordinator(evaluator: session.evaluator)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        guard let url = session.origin.url(path: "/") else { return webView }
        let cookies = session.cookies
        let store = configuration.websiteDataStore

        Task { @MainActor in
            await CookieInstaller.install(cookies, into: store)
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let evaluator: PinnedTrustEvaluator

        init(evaluator: PinnedTrustEvaluator) {
            self.evaluator = evaluator
            super.init()
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            switch evaluator.evaluate(trust, host: space.host) {
            case .allowed:
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .rejected:
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // Left visible in the Xcode console; the page itself reports its state.
            let message = "gateway load failed: " + error.localizedDescription
                + " (" + String((error as NSError).code) + ")"
            NSLog("%@", message)
        }
    }
}
