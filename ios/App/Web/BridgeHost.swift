import Foundation
import WebKit
import DSHPairing
import DSHBridge
import DSHTransport
import DSHTrust

/// Receives page messages, validates them, and answers through the injected
/// delivery function.
///
/// WKScriptMessageHandler gives no origin guarantee, so the frame and its
/// security origin are checked here (docs/02 section 4.3).
final class BridgeHost: NSObject, WKScriptMessageHandler {
    private let origin: GatewayOrigin
    private let evaluator: PinnedTrustEvaluator
    private let deviceToken: String?
    private let onSwitchComputer: (() -> Void)?
    private let pending = BridgePendingTracker()

    weak var webView: WKWebView?

    init(
        origin: GatewayOrigin,
        evaluator: PinnedTrustEvaluator,
        deviceToken: String?,
        onSwitchComputer: (() -> Void)? = nil
    ) {
        self.origin = origin
        self.evaluator = evaluator
        self.deviceToken = deviceToken
        self.onSwitchComputer = onSwitchComputer
        super.init()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == BridgeScript.handlerName else { return }
        guard message.frameInfo.isMainFrame else { return }
        guard isTrusted(origin: message.frameInfo.securityOrigin) else { return }
        guard let text = message.body as? String else { return }

        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let event = object["event"] as? String {
            appendLog("event " + event)
            return
        }

        let request: BridgeRequest
        do {
            request = try BridgeRequest.parse(text)
        } catch let error as BridgeError {
            reply(BridgeReply.failure(requestId: "<unknown>", code: error.code, message: error.description))
            return
        } catch {
            reply(BridgeReply.failure(requestId: "<unknown>", code: .badMessage, message: "unreadable message"))
            return
        }

        appendLog("invoke " + request.action)

        guard pending.begin(request.requestId) else {
            reply(BridgeReply.failure(requestId: request.requestId, code: .badMessage, message: "duplicate or too many pending requests"))
            return
        }

        Task { @MainActor in
            let reply = await self.handle(request)
            self.pending.finish(request.requestId)
            self.reply(reply)
        }
    }

    private func isTrusted(origin security: WKSecurityOrigin) -> Bool {
        security.host == origin.host
            && security.port == origin.effectivePort
            && security.protocol == origin.scheme
    }

    private func handle(_ request: BridgeRequest) async -> BridgeReply {
        switch request.action {
        case BridgeAction.authRenew.rawValue:
            do {
                let renewed = try await renew()
                if let webView {
                    await CookieInstaller.install(
                        SessionCookiePlan.cookies(for: origin, session: renewed),
                        into: webView.configuration.websiteDataStore
                    )
                }
                return BridgeReply.success(requestId: request.requestId, value: ["renewed": true])
            } catch let failure as MobileAccessFailure {
                return BridgeReply.failure(requestId: request.requestId, code: .failed, message: failure.description)
            } catch {
                return BridgeReply.failure(requestId: request.requestId, code: .failed, message: error.localizedDescription)
            }
        case BridgeAction.switchComputer.rawValue:
            // The page asked for the computer list; pop back to the app's list.
            onSwitchComputer?()
            return BridgeReply.success(requestId: request.requestId, value: ["switched": true])
        default:
            return BridgeReply.failure(
                requestId: request.requestId,
                code: .unsupported,
                message: "action not implemented: " + request.action
            )
        }
    }

    private func renew() async throws -> SessionCredential {
        guard let deviceToken else {
            throw MobileAccessFailure.pairingExpired
        }
        let delegate = PinnedSessionDelegate(evaluator: evaluator)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { urlSession.finishTasksAndInvalidate() }

        let client = MobileAccessClient(
            origin: origin,
            transport: URLSessionTransport(session: urlSession),
            expectedInstanceId: nil
        )
        return try await client.renew(deviceToken: deviceToken)
    }

    private func appendLog(_ line: String) {
        Task { @MainActor in
            BridgeLog.shared.append(line)
        }
    }

    private func reply(_ reply: BridgeReply) {
        appendLog(reply.ok ? "reply ok" : "reply failed")
        guard let webView else { return }
        let literal = BridgeHost.javaScriptLiteral(reply.json())
        webView.evaluateJavaScript("window.__DSH_MOBILE_NATIVE_DELIVER__(" + literal + ");") { _, error in
            if let error {
                NSLog("%@", "bridge delivery failed: " + error.localizedDescription)
            }
        }
    }

    /// Encodes a string as a JS literal without hand-rolled escaping.
    static func javaScriptLiteral(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
