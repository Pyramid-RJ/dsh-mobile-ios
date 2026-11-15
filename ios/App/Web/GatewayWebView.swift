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
    @State private var loadFailure: String?
    @State private var isLoading = true

    var body: some View {
        GatewayWebView(
            session: session,
            onSwitchComputer: { dismiss() },
            onDeviceRevoked: {
                onDeviceRevoked?(session)
                dismiss()
            },
            onLoadFailure: { message in
                loadFailure = message
                isLoading = false
            },
            onPageLoaded: {
                isLoading = false
            }
        )
            .overlay {
                if let loadFailure {
                    loadFailureOverlay(loadFailure)
                } else if isLoading {
                    loadingOverlay
                }
            }
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

    /// The page needs a few seconds (cookies, then the gateway's own plugin
    /// load); a spinner says so instead of an empty white view.
    private var loadingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载页面…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false)
    }

    /// F-2.4: a first-screen failure has to offer a way out - retry, or leave.
    private func loadFailureOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("页面没有加载出来")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("重试") {
                    loadFailure = nil
                    BridgeHostRegistry.shared.current?.reload()
                }
                .buttonStyle(.borderedProminent)
                Button("返回") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(32)
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
    var onLoadFailure: ((String) -> Void)?
    var onPageLoaded: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            onSwitchComputer: onSwitchComputer,
            onDeviceRevoked: onDeviceRevoked,
            onLoadFailure: onLoadFailure,
            onPageLoaded: onPageLoaded
        )
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
            BridgeLog.shared.append("loading page", detail: url.absoluteString + " · \(cookies.count) cookie(s)")
            await CookieInstaller.install(cookies, into: store)
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Leaving the page should stop whatever it was doing: a dismissed web view
    /// keeps timers and media running otherwise.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: BridgeScript.handlerName)
        let host = coordinator.bridgeHost
        Task { @MainActor in
            if BridgeHostRegistry.shared.current === host {
                BridgeHostRegistry.shared.current = nil
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let bridgeHost: BridgeHost
        /// Only what a handler can actually serve (docs/03 section 6.2).
        let capabilities: BridgeCapabilities

        private let evaluator: any GatewayTrustEvaluating

        private let onLoadFailure: ((String) -> Void)?
        private let onPageLoaded: (() -> Void)?

        init(
            session: BrowserSession,
            onSwitchComputer: (() -> Void)?,
            onDeviceRevoked: (() -> Void)?,
            onLoadFailure: ((String) -> Void)? = nil,
            onPageLoaded: (() -> Void)? = nil
        ) {
            self.onLoadFailure = onLoadFailure
            self.onPageLoaded = onPageLoaded
            evaluator = session.evaluator
            let advertised = BridgeCapabilities(implemented: [
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
            capabilities = advertised
            bridgeHost = BridgeHost(
                origin: session.origin,
                evaluator: session.evaluator,
                deviceToken: session.deviceToken,
                onSwitchComputer: onSwitchComputer,
                onDeviceRevoked: onDeviceRevoked,
                capabilities: advertised
            )
            super.init()
        }

        /// Records whether the gateway actually served the dedicated page: the
        /// page only takes the native branch when these markers are present.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let loaded = onPageLoaded
            Task { @MainActor in loaded?() }
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

            let decision = evaluator.evaluate(trust, host: space.host)
            switch decision {
            case .allowed:
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .rejected(let failure):
                // A TLS refusal has to be readable on the device: "CA 已过期"
                // and "fingerprint mismatch" need different actions.
                Task { @MainActor in
                    BridgeLog.shared.append("tls rejected", detail: space.host + " · " + failure.description)
                }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            NSLog("%@", "gateway load failed: " + error.localizedDescription + " (" + String(nsError.code) + ")")
            Task { @MainActor in
                BridgeLog.shared.append("gateway load failed", detail: error.localizedDescription)
                self.onLoadFailure?(Self.describe(error))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            // A cancelled load is what a redirect or a user gesture looks like;
            // only a real failure deserves the overlay.
            guard nsError.code != NSURLErrorCancelled else { return }
            Task { @MainActor in
                BridgeLog.shared.append("gateway navigation failed", detail: error.localizedDescription)
                self.onLoadFailure?(Self.describe(error))
            }
        }

        /// Turns the NSURLError into something a person can act on.
        private static func describe(_ error: Error) -> String {
            let nsError = error as NSError
            switch nsError.code {
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorSecureConnectionFailed:
                return "证书校验失败（\(nsError.code)）：电脑端的 CA 可能已更换或过期，请重新配对。"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorTimedOut:
                return "连不上电脑（\(nsError.code)）：确认电脑开着、和手机在同一网络，或隧道是否在线。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "网络不可用（\(nsError.code)）：检查 Wi-Fi 或蜂窝。"
            default:
                return error.localizedDescription + "（\(nsError.code)）"
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("%@", "web content process terminated")
        }
    }
}
