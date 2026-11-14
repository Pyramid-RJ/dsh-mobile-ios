import SwiftUI
import UIKit
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
    /// Height of the software keyboard, 0 when it is down. Drives the bar that
    /// sits right above it.
    @State private var keyboardHeight: CGFloat = 0

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
            // The page's Enter translation never fires on this device, so the
            // newline lives next to the keyboard instead of in the app's top bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardHeight > 0 {
                    composerBar
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                keyboardHeight = Self.keyboardHeight(from: end)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .sheet(isPresented: $showsLog) {
                BridgeLogScreen()
            }
    }

    private var composerBar: some View {
        HStack(spacing: 18) {
            Button {
                insertLineBreak()
            } label: {
                Label("换行", systemImage: "return")
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            Button("完成") {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    /// Keyboard height from its end frame, 0 when it is off screen.
    private static func keyboardHeight(from frame: CGRect?) -> CGFloat {
        guard let frame else { return 0 }
        let screen = UIScreen.main.bounds
        let overlap = max(0, screen.maxY - frame.minY)
        return overlap > 1 ? overlap : 0
    }

    /// The page's own Enter translation never fires on this device, so the shell
    /// offers the same result directly: a line break in the focused draft.
    /// `execCommand` goes through WebKit's editing pipeline, which is what the
    /// editor listens to; a synthetic key event would not be trusted.
    private func insertLineBreak() {
        let script = """
        (function () {
          var el = document.activeElement;
          if (!el || !(el.isContentEditable || el.tagName === 'TEXTAREA')) { return 'no-editor'; }
          try { if (document.execCommand('insertLineBreak')) { return 'ok'; } } catch (e) {}
          try { if (document.execCommand('insertText', false, '\\n')) { return 'ok-text'; } } catch (e) {}
          return 'failed';
        })();
        """
        BridgeHostRegistry.shared.current?.runInPage(script) { result in
            Task { @MainActor in
                BridgeLog.shared.append("insert line break", detail: String(describing: result ?? "nil"))
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
            // The frame notification carries the end frame, which is the only
            // reliable way to tell "moved" from "gone": WillShow/WillHide are
            // not always paired for a WKWebView keyboard.
            let change = center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
            ) { [weak self, weak webView] note in
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                self?.keyboardVisible = Self.isKeyboardFrameVisible(end)
                self?.publishKeyboardState(to: webView)
            }
            let hide = center.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self, weak webView] _ in
                self?.keyboardVisible = false
                self?.publishKeyboardState(to: webView)
            }
            keyboardObservers = [change, hide]
            publishKeyboardState(to: webView)
        }

        /// A keyboard frame that starts above the bottom edge is on screen.
        private static func isKeyboardFrameVisible(_ frame: CGRect?) -> Bool {
            guard let frame, frame.height > 0 else { return false }
            let screenHeight = UIScreen.main.bounds.height
            return frame.minY < screenHeight - 1
        }

        func stopKeyboardReporting() {
            let center = NotificationCenter.default
            keyboardObservers.forEach { center.removeObserver($0) }
            keyboardObservers = []
        }

        private func publishKeyboardState(to webView: WKWebView?) {
            guard let webView else { return }
            let visible = keyboardVisible ? "true" : "false"
            // `noHardwareKeyboard: false` keeps the page's Enter translation off:
            // it never produced a newline on this device (the page requires
            // inputmode != none and loses it to its own withhold), so Enter keeps
            // its original meaning - send - and the keyboard bar's 换行 button is
            // the explicit way to insert a line break.
            let script = "window.__DSH_MOBILE_KEYBOARD_STATE__ = { imeVisible: " + visible
                + ", noHardwareKeyboard: false };"
            webView.evaluateJavaScript(script)
            // The page's Enter handling hangs off this value, so it has to be
            // visible in the log when it misbehaves.
            Task { @MainActor in
                BridgeLog.shared.append("keyboard state", detail: "imeVisible=" + visible)
            }
        }

        /// Records whether the gateway actually served the dedicated page: the
        /// page only takes the native branch when these markers are present.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A new document starts without the global; republish it.
            publishKeyboardState(to: webView)
            // Record what the page actually sees, so a wrong Enter behaviour can
            // be traced to this value instead of guessed at.
            webView.evaluateJavaScript("JSON.stringify(window.__DSH_MOBILE_KEYBOARD_STATE__)") { result, _ in
                guard let text = result as? String else { return }
                Task { @MainActor in
                    BridgeLog.shared.append("page sees keyboard", detail: text)
                }
            }
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
