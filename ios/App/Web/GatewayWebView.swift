import SwiftUI
import WebKit
import DSHPairing
import DSHBridge
import DSHTrust

struct GatewayWebViewScreen: View {
    let session: BrowserSession
    /// Called when the page reports that the computer revoked this device.
    var onDeviceRevoked: ((BrowserSession) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showsLog = false

    var body: some View {
        GatewayWebView(
            session: session,
            onSwitchComputer: { dismiss() },
            onDeviceRevoked: {
                onDeviceRevoked?(session)
                dismiss()
            }
        )
            .navigationTitle(session.origin.host)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        goBack()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("返回")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("桥日志") { showsLog = true }
                }
            }
            .sheet(isPresented: $showsLog) {
                BridgeLogScreen()
            }
    }

    /// Back is the page's decision first (docs/03 §7.1): if it closed a drawer,
    /// a panel or a dialog it says so and the shell stays; otherwise the shell
    /// leaves the page.
    private func goBack() {
        guard let host = BridgeHostRegistry.shared.current else {
            dismiss()
            return
        }
        host.dispatchNativeBack { handled in
            Task { @MainActor in
                BridgeLog.shared.append("native-back", detail: handled ? "page handled" : "leaving the page")
                if !handled {
                    dismiss()
                }
            }
        }
    }
}

/// Loads the gateway with the pinned CA, installs the session cookies first, and
/// injects the bridge adapter at document start.
struct GatewayWebView: UIViewRepresentable {
    let session: BrowserSession
    var onSwitchComputer: (() -> Void)?
    var onDeviceRevoked: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onSwitchComputer: onSwitchComputer, onDeviceRevoked: onDeviceRevoked)
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
        // Temporary: the composer cannot delete its command chips on iOS
        // (docs/10). Remove once the upstream fix ships.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ComposerChipShim.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        host.webView = webView
        BridgeHostRegistry.shared.current = host

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
        let capabilities = BridgeCapabilities(implemented: [
            .authRenew,
            .switchComputer,
            .clipboardRead,
            .clipboardWrite,
            .displayScaleGet,
            .displayScaleSet,
            .share,
            .filesPick,
            .cameraCapture,
            .deviceRevoked,
        ])

        private let evaluator: PinnedTrustEvaluator

        init(session: BrowserSession, onSwitchComputer: (() -> Void)?, onDeviceRevoked: (() -> Void)?) {
            evaluator = session.evaluator
            bridgeHost = BridgeHost(
                origin: session.origin,
                evaluator: session.evaluator,
                deviceToken: session.deviceToken,
                onSwitchComputer: onSwitchComputer,
                onDeviceRevoked: onDeviceRevoked
            )
            super.init()
        }

        /// Records whether the gateway actually served the dedicated page: the
        /// page only takes the native branch when these markers are present.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = """
            (function () {
              var meta = document.querySelector('meta[name="dsh-mobile-gateway"]');
              return [
                'frontend=' + String(window.__DSH_MOBILE_FRONTEND__),
                'gateway=' + (meta ? meta.getAttribute('content') : 'none'),
                'bridge=' + (typeof window.__DSH_MOBILE_NATIVE__),
                'path=' + location.pathname
              ].join(' | ');
            })();
            """
            webView.evaluateJavaScript(script) { result, _ in
                guard let text = result as? String else { return }
                Task { @MainActor in
                    BridgeLog.shared.append(text)
                }
            }
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
