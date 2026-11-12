import Foundation
import SwiftUI
import WebKit
import DSHPairing
import DSHTrust

/// Runs the S-1 experiment on a real device: fetch the gateway CA through the
/// bounded bootstrap window, pin it, then load the gateway in a WKWebView and
/// see whether WebKit lets a custom trust decision through.
///
/// The outcome that matters is written by the navigation delegate below:
/// - a "challenge" line means WebKit asked us about the server trust at all;
/// - "固定 CA 通过" plus "didFinish" means the pinned decision was accepted;
/// - no challenge line plus a -1202 error means ATS/WebKit refused earlier.
struct S1ProbeView: View {
    @State private var gateway = "https://"
    @State private var logs: [ProbeLogEntry] = []
    @State private var verdict = "未运行"
    @State private var isLoading = false
    @State private var session: ProbeSession?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("网关") {
                    TextField("https://192.168.1.5:3443", text: $gateway)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(isLoading ? "请求中…" : "取 CA 并加载页面") { run() }
                        .disabled(isLoading)
                }
                Section("结论") {
                    Text(verdict)
                        .font(.footnote)
                }
            }
            .frame(height: 210)

            if let session {
                PinnedWebView(session: session, onLog: append)
                    .id(session.url)
                    .frame(height: 260)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logs) { entry in
                        Text(entry.text)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle("S-1 探针")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func append(_ message: String) {
        logs.append(ProbeLogEntry(text: message))

        if message.hasPrefix("didFinish") {
            verdict = "挑战已被接受，页面加载完成 —— 本机初步通过"
        } else if message.hasPrefix("didFailProvisionalNavigation") {
            verdict = "加载失败：日志里若没有任何 challenge，说明证书被系统拦在 challenge 之前"
        } else if message.contains("拒绝") {
            verdict = "固定 CA 被拒绝，原因见日志"
        }
    }

    private func run() {
        logs = []
        session = nil
        isLoading = true
        verdict = "请求中…"

        let input = gateway
        Task { @MainActor in
            do {
                let origin = try PairingLink.parse(input).origin
                append("Origin: " + origin.description)

                let ca = try await fetchCertificateAuthority(origin: origin)
                append("CA subject: " + ca.subjectSummary)
                append("CA sha256: " + ca.sha256Hex)

                guard let url = origin.url(path: "/") else { throw ProbeFailure.invalidURL }
                session = ProbeSession(url: url, evaluator: PinnedTrustEvaluator(certificateAuthority: ca))
                verdict = "已固定 CA，开始加载"
            } catch {
                verdict = "失败：" + error.localizedDescription
                append("error: " + String(describing: error))
            }
            isLoading = false
        }
    }

    private func fetchCertificateAuthority(origin: GatewayOrigin) async throws -> CertificateAuthority {
        guard let url = origin.url(path: "/mobile-access/ca.cer") else {
            throw ProbeFailure.invalidURL
        }

        // Bootstrap window: no CA is pinned yet, so this request alone runs
        // without verification, and only against the documented path.
        let delegate = BootstrapOnlyTrustDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { urlSession.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeFailure.notACertificate
        }
        guard http.statusCode == 200 else {
            throw ProbeFailure.unexpectedStatus(http.statusCode)
        }
        guard let ca = CertificateAuthority.parse(data) else {
            throw ProbeFailure.notACertificate
        }
        return ca
    }
}

enum ProbeFailure: LocalizedError {
    case invalidURL
    case unexpectedStatus(Int)
    case notACertificate

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "网关地址无效"
        case .unexpectedStatus(let code):
            return "网关返回 HTTP " + String(code) + "（404 表示这个网关没有私有 CA）"
        case .notACertificate:
            return "响应无法解析成证书"
        }
    }
}

struct ProbeLogEntry: Identifiable {
    let id = UUID()
    let text: String
}

struct ProbeSession {
    let url: URL
    let evaluator: PinnedTrustEvaluator
}

/// A WKWebView that answers its TLS challenge with the pinned CA and reports
/// every step, so the experiment is observable instead of a black box.
struct PinnedWebView: UIViewRepresentable {
    let session: ProbeSession
    let onLog: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(evaluator: session.evaluator, onLog: onLog)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        let target = session.url
        let log = onLog
        DispatchQueue.main.async {
            log("load " + target.absoluteString)
        }
        webView.load(URLRequest(url: target))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let evaluator: PinnedTrustEvaluator
        private let onLog: (String) -> Void
        private var challengeCount = 0

        init(evaluator: PinnedTrustEvaluator, onLog: @escaping (String) -> Void) {
            self.evaluator = evaluator
            self.onLog = onLog
            super.init()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLog("didStartProvisionalNavigation")
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            challengeCount += 1
            let space = challenge.protectionSpace
            onLog("challenge #" + String(challengeCount) + " " + space.authenticationMethod + " host=" + space.host)

            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            switch evaluator.evaluate(trust, host: space.host) {
            case .allowed:
                onLog("  → 固定 CA 通过，提交凭据")
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .rejected(let failure):
                onLog("  → 拒绝：" + failure.description)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLog("didFinish 页面加载完成")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onLog("didFailProvisionalNavigation " + error.localizedDescription + " code=" + String((error as NSError).code))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLog("didFail " + error.localizedDescription + " code=" + String((error as NSError).code))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onLog("web content process terminated")
        }
    }
}
