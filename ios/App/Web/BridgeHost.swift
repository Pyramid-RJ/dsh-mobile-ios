import Foundation
import UIKit
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

        case BridgeAction.share.rawValue:
            guard let text = request.input["text"] as? String else {
                return BridgeReply.failure(
                    requestId: request.requestId,
                    code: .badMessage,
                    message: "share needs a string 'text'"
                )
            }
            await MainActor.run { SharePresenter.present(text: text) }
            return BridgeReply.success(requestId: request.requestId, value: ["shared": true])

        case BridgeAction.filesPick.rawValue:
            return await pickFile(request)

        case BridgeAction.cameraCapture.rawValue:
            return await capturePhoto(request)

        case BridgeAction.clipboardRead.rawValue:
            let text = await MainActor.run { UIPasteboard.general.string } ?? ""
            return BridgeReply.success(requestId: request.requestId, value: ["text": text])

        case BridgeAction.clipboardWrite.rawValue:
            guard let text = request.input["text"] as? String else {
                return BridgeReply.failure(
                    requestId: request.requestId,
                    code: .badMessage,
                    message: "clipboard.write needs a string 'text'"
                )
            }
            guard text.utf8.count <= BridgeLimits.maxClipboardBytes else {
                return BridgeReply.failure(
                    requestId: request.requestId,
                    code: .payloadTooLarge,
                    message: "clipboard text exceeds 256 KiB"
                )
            }
            await MainActor.run { UIPasteboard.general.string = text }
            return BridgeReply.success(requestId: request.requestId, value: ["written": true])

        case BridgeAction.displayScaleGet.rawValue:
            let percent = DisplayScaleStore.shared.percent
            return BridgeReply.success(requestId: request.requestId, value: DisplayScalePolicy.reply(percent: percent))

        case BridgeAction.displayScaleSet.rawValue:
            guard let percent = DisplayScalePolicy.percent(from: request.input) else {
                return BridgeReply.failure(
                    requestId: request.requestId,
                    code: .badMessage,
                    message: "display scale must be an integer from 80 to 125"
                )
            }
            DisplayScaleStore.shared.percent = percent
            await applyViewport(percent: percent)
            return BridgeReply.success(requestId: request.requestId, value: DisplayScalePolicy.reply(percent: percent))
        default:
            return BridgeReply.failure(
                requestId: request.requestId,
                code: .unsupported,
                message: "action not implemented: " + request.action
            )
        }
    }

    @MainActor
    private func presenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func pickFile(_ request: BridgeRequest) async -> BridgeReply {
        guard let presenter = await presenter() else {
            return BridgeReply.failure(requestId: request.requestId, code: .unavailable, message: "no presenter")
        }
        do {
            let file = try await FilePicker().pick(from: presenter)
            return BridgeReply.success(requestId: request.requestId, value: file.bridgeValue)
        } catch let failure as PickFailure {
            return BridgeReply.failure(
                requestId: request.requestId,
                code: failure == .cancelled ? .cancelled : (isTooLarge(failure) ? .payloadTooLarge : .failed),
                message: failure.description
            )
        } catch {
            return BridgeReply.failure(requestId: request.requestId, code: .failed, message: error.localizedDescription)
        }
    }

    private func capturePhoto(_ request: BridgeRequest) async -> BridgeReply {
        guard CameraCapture.isAvailable else {
            return BridgeReply.failure(
                requestId: request.requestId,
                code: .unavailable,
                message: "no camera on this device"
            )
        }
        guard let presenter = await presenter() else {
            return BridgeReply.failure(requestId: request.requestId, code: .unavailable, message: "no presenter")
        }
        do {
            let file = try await CameraCapture().capture(from: presenter)
            return BridgeReply.success(requestId: request.requestId, value: file.bridgeValue)
        } catch let failure as PickFailure {
            return BridgeReply.failure(
                requestId: request.requestId,
                code: failure == .cancelled ? .cancelled : (isTooLarge(failure) ? .payloadTooLarge : .failed),
                message: failure.description
            )
        } catch {
            return BridgeReply.failure(requestId: request.requestId, code: .failed, message: error.localizedDescription)
        }
    }

    private func isTooLarge(_ failure: PickFailure) -> Bool {
        if case .tooLarge = failure { return true }
        return false
    }

    /// Rewrites the viewport meta tag the way the page expects (docs/03 section 6.1).
    @MainActor
    private func applyViewport(percent: Int) async {
        guard let webView else { return }
        let width = Int((webView.bounds.width * UIScreen.main.scale).rounded())
        let density = Double(UIScreen.main.scale)
        let viewport = DisplayScalePolicy.viewportWidth(
            nativeWidth: Double(width),
            density: density,
            percent: percent
        )
        let script = """
        (function () {
          var meta = document.querySelector('meta[name="viewport"]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.setAttribute('name', 'viewport');
            document.head.appendChild(meta);
          }
          meta.setAttribute('content', 'width=(viewport), initial-scale=1');
        })();
        """
        _ = try? await webView.evaluateJavaScript(script)
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
