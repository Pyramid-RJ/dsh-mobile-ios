import Combine
import Foundation
import DSHPairing
import DSHTransport
import DSHDeviceStore
import DSHTrust

/// Restores a previously paired computer and keeps the stored book in memory.
///
/// This is what makes "reopen the app and be back in DSH" work (US-4): the
/// credential and the pinned CA live in the Keychain, so nothing is re-typed
/// after a relaunch or a 7-day re-sign.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [DeviceRecord] = []
    @Published private(set) var status = "未加载"
    @Published private(set) var session: BrowserSession?
    @Published private(set) var log: [String] = []

    private let store = KeychainDeviceRecordStore()

    func restore() async {
        do {
            devices = try store.load().records
        } catch {
            status = "读取配对记录失败：" + error.localizedDescription
            return
        }

        guard let first = devices.first else {
            status = "还没有配对的电脑"
            return
        }
        await connect(first)
    }

    func connect(_ record: DeviceRecord) async {
        session = nil
        log = []
        status = "连接 " + record.displayName + "…"

        do {
            if record.isExpired() {
                throw MobileAccessFailure.deviceExpired
            }
            let origin = try PairingLink.parse(record.origin).origin
            guard let authority = CertificateAuthority(der: record.certificateAuthority) else {
                throw PairingFlowError.notACertificate
            }

            let evaluator = PinnedTrustEvaluator(certificateAuthority: authority)
            let delegate = PinnedSessionDelegate(evaluator: evaluator)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { urlSession.finishTasksAndInvalidate() }

            let client = MobileAccessClient(
                origin: origin,
                transport: URLSessionTransport(session: urlSession),
                expectedInstanceId: record.instanceId
            )

            _ = try await client.probe(deviceToken: record.deviceToken)
            append("probe ok")
            let renewed = try await client.renew(deviceToken: record.deviceToken)
            append("renew ok，会话到期 " + ISO8601DateFormatter().string(from: renewed.sessionExpiresAt))

            session = BrowserSession(
                origin: origin,
                evaluator: evaluator,
                cookies: SessionCookiePlan.cookies(for: origin, session: renewed),
                deviceToken: record.deviceToken
            )
            status = "已连接 " + record.displayName
        } catch {
            status = "连接失败：" + error.localizedDescription
            append("error: " + String(describing: error))
        }
    }

    func forgetAll() {
        try? store.delete()
        devices = []
        session = nil
        status = "已清除本机配对记录"
    }

    private func append(_ line: String) {
        log.append(line)
    }
}
