import Combine
import Foundation
import DSHPairing
import DSHTransport
import DSHDeviceStore
import DSHTrust

/// Everything the web screen needs to open the gateway with pinned trust.
struct BrowserSession {
    let origin: GatewayOrigin
    let evaluator: PinnedTrustEvaluator
    let cookies: [PlannedCookie]
    /// Needed by the bridge's auth.renew handler; nil for the S-1 probe.
    let deviceToken: String?
}

/// P1 happy path: link -> CA -> verify fingerprint -> pair -> renew -> store -> load.
@MainActor
final class PairingCoordinator: ObservableObject {
    @Published private(set) var status = "尚未配对"
    @Published private(set) var log: [String] = []
    @Published private(set) var session: BrowserSession?
    /// True while a pairing is in flight, so the UI can disable its buttons.
    @Published private(set) var isPairing = false

    private let store = KeychainDeviceRecordStore()

    func pair(input: String) async {
        log = []
        session = nil
        status = "准备中…"
        isPairing = true
        defer { isPairing = false }

        do {
            let link = try PairingLink.parse(input)
            append("Origin " + link.origin.description)

            guard let token = link.token else { throw PairingFlowError.missingToken }

            status = "取 CA…"
            let authority = try await BootstrapCAFetcher.fetch(origin: link.origin)
            append("CA " + authority.subjectSummary)
            append("CA sha256 " + authority.sha256Hex)

            if let expected = link.instanceId {
                guard authority.matches(instanceId: expected) else {
                    throw PairingFlowError.instanceMismatch(expected: expected, actual: authority.sha256Hex)
                }
                append("instance 指纹一致")
            } else {
                append("链接未带 instance，跳过指纹比对（建议重新扫码）")
            }

            let evaluator = PinnedTrustEvaluator(certificateAuthority: authority)
            let sessionDelegate = PinnedSessionDelegate(evaluator: evaluator)

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let urlSession = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
            defer { urlSession.finishTasksAndInvalidate() }

            let client = MobileAccessClient(
                origin: link.origin,
                transport: URLSessionTransport(session: urlSession),
                expectedInstanceId: authority.sha256Hex
            )

            status = "配对…"
            let credential = try await client.pair(token: token)
            append("设备已登记：" + String(credential.deviceId.prefix(8)) + "…")

            status = "续期会话…"
            let renewed = try await client.renew(deviceToken: credential.deviceToken)
            append("会话到期 " + ISO8601DateFormatter().string(from: renewed.sessionExpiresAt))

            var book: DeviceRecordBook
            do {
                book = try store.load()
            } catch {
                // Never overwrite unreadable credentials with a fresh book.
                append("读取已有记录失败：" + error.localizedDescription)
                throw error
            }

            let record = DeviceRecord(
                displayName: link.origin.host,
                origin: link.origin.description,
                instanceId: credential.instanceId,
                deviceId: credential.deviceId,
                deviceToken: credential.deviceToken,
                deviceExpiresAt: credential.deviceExpiresAt,
                certificateAuthority: authority.der,
                lastConnectedAt: Date()
            )
            book.upsert(record)
            try store.save(book)
            append("已写入 Keychain，共 " + String(book.records.count) + " 台")

            session = BrowserSession(
                origin: link.origin,
                evaluator: evaluator,
                cookies: SessionCookiePlan.cookies(for: link.origin, session: renewed),
                deviceToken: credential.deviceToken
            )
            status = "已就绪，点「打开 DSH 页面」"
        } catch {
            status = "失败：" + error.localizedDescription
            append("error: " + String(describing: error))
        }
    }

    private func append(_ line: String) {
        log.append(line)
    }
}
