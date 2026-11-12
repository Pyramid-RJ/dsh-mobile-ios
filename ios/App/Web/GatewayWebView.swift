import SwiftUI
import WebKit
import DSHPairing
import DSHBridge
import DSHTrust

struct GatewayWebViewScreen: View {
    let session: BrowserSession

    @ObservedObject private var bridgeLog = BridgeLog.shared
    @State private var showsLog = false

    var body: some View {
        GatewayWebView(session: session)
            .navigationTitle(session.origin.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("桥日志") { showsLog = true }
                }
            }
            .sheet(isPresented: $showsLog) {
                NavigationStack {
                    List(bridgeLog.entries, id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                    }
                    .navigationTitle("桥日志")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { showsLog = false }
                        }
                    }
                }
            }
    }
}

/// Loads the gateway with the pinned CA, installs the session cookies first, and
/// injects the bridge adapter at document start.
struct GatewayWebView: UIViewRepresentable {
    let session: BrowserSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let host = context.coordinator.bridgeHost
        configuration.userContentController.add(host, name: BridgeScript.handlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BridgeScript.make(capabilities: context.coordinator.capabilities),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        host.webView = webView

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
        let bridgeHost: BridgeHost
        /// Only what a handler can actually serve (docs/03 section 6.2).
        let capabilities = BridgeCapabilities(implemented: [.authRenew])

        private let evaluator: PinnedTrustEvaluator

        init(session: BrowserSession) {
            evaluator = session.evaluator
            bridgeHost = BridgeHost(
                origin: session.origin,
                evaluator: session.evaluator,
                deviceToken: session.deviceToken
            )
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
            NSLog("%@", "gateway load failed: " + error.localizedDescription + " (" + String((error as NSError).code) + ")")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("%@", "web content process terminated")
        }
    }
}
