import Foundation
import DSHPairing
import DSHTransport
import DSHTrust

/// Checks that a gateway address answers at all, before pairing is attempted.
///
/// Built for the remote path (docs/12 B2): a tunnel address cannot be verified
/// by discovery, so the app offers a plain "does this address answer" probe that
/// uses the system trust store and never touches the pairing credentials.
enum RemoteHealthProbe {
    struct Result: Equatable {
        let ok: Bool
        let detail: String
    }

    /// - Parameter text: a pairing link or a bare origin, as typed by the user.
    static func check(_ text: String) async -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(ok: false, detail: "输入为空")
        }
        let origin: GatewayOrigin
        do {
            origin = try PairingLink.parse(trimmed).origin
        } catch {
            return Result(ok: false, detail: "地址无效：" + String(describing: error))
        }
        guard let url = origin.url(path: MobileAccessEndpoint.health.rawValue) else {
            return Result(ok: false, detail: "无法构造请求地址")
        }

        let delegate = PinnedSessionDelegate(evaluator: SystemTrustEvaluator())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return Result(ok: false, detail: "响应不是 HTTP")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 200 {
                return Result(ok: true, detail: "HTTP 200 · " + origin.description + " · " + body.prefix(80))
            }
            return Result(ok: false, detail: "HTTP " + String(http.statusCode) + " · " + origin.description)
        } catch {
            return Result(ok: false, detail: "连接失败：" + error.localizedDescription)
        }
    }
}
