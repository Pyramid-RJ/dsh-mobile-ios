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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("桥日志") { showsLog = true }
                }
            }
            .sheet(isPresented: $showsLog) {
                BridgeLogScreen()
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
        // Temporary: the composer cannot delete its command chips, and the
        // keyboard returns over the open attachment menu (docs/10). Remove once
        // the upstream fixes ship.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ComposerShim.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        host.webView = webView
        BridgeHostRegistry.shared.current = host
        context.coordinator.startKeyboardReporting(for: webView)

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

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopKeyboardReporting()
    }

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
        /// Whether the software keyboard is up right now (docs/03 section 7).
        private var keyboardVisible = false
        private var keyboardObservers: [NSObjectProtocol] = []

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

        /// Publishes `window.__DSH_MOBILE_KEYBOARD_STATE__`, which the mobile
        /// layout reads to decide whether a soft keyboard exists. Without it the
        /// page cannot tell an open keyboard from a closed one, and every
        /// composer control has to guess.
        func startKeyboardReporting(for webView: WKWebView) {
            let center = NotificationCenter.default
            let show = center.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self, weak webView] _ in
                self?.keyboardVisible = true
                self?.publishKeyboardState(to: webView)
            }
            let hide = center.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self, weak webView] _ in
                self?.keyboardVisible = false
                self?.publishKeyboardState(to: webView)
            }
            keyboardObservers = [show, hide]
            publishKeyboardState(to: webView)
        }

        func stopKeyboardReporting() {
            let center = NotificationCenter.default
            keyboardObservers.forEach { center.removeObserver($0) }
            keyboardObservers = []
        }

        private func publishKeyboardState(to webView: WKWebView?) {
            guard let webView else { return }
            let visible = keyboardVisible ? "true" : "false"
            let script = "window.__DSH_MOBILE_KEYBOARD_STATE__ = { imeVisible: " + visible
                + ", noHardwareKeyboard: true };"
            webView.evaluateJavaScript(script)
        }

        /// Records whether the gateway actually served the dedicated page: the
        /// page only takes the native branch when these markers are present.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A new document starts without the global; republish it.
            publishKeyboardState(to: webView)
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
