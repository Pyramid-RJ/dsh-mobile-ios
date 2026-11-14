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
///
/// P2 adds the edits the device list needs (rename, reorder, delete) and a
/// reachability probe. Every edit goes through `DeviceRecordBook` and is written
/// back immediately: the Keychain is the only copy, so a rename that is not
/// saved is a rename that never happened.
@MainActor
final class AppModel: ObservableObject {
    /// What the list can say about a stored computer right now.
    enum Reachability: Equatable {
        case unknown
        case checking
        case reachable
        case unreachable(String)
    }

    /// Where the app stands with the stored computers.
    enum Connection: Equatable {
        case idle
        case connecting(String)
        case connected(String)
        /// The computer no longer accepts this device (docs/06 P0-09).
        case revoked(String)
        case failed(String, String)
    }

    @Published private(set) var devices: [DeviceRecord] = []
    @Published private(set) var status = "未加载"
    @Published private(set) var session: BrowserSession?
    @Published private(set) var log: [String] = []
    @Published private(set) var reachability: [UUID: Reachability] = [:]
    @Published private(set) var connection: Connection = .idle
    /// Records found on a fresh install: the user picks keep or discard (P1-12).
    @Published private(set) var pendingRecovery: [DeviceRecord] = []
    /// Computers that answered `device_revoked`; they are not auto-connected.
    @Published private(set) var revoked: Set<UUID> = []

    private let store = KeychainDeviceRecordStore()
    private var book = DeviceRecordBook()

    /// True while the "old credentials found" prompt is unanswered.
    var isAwaitingRecoveryDecision: Bool { !pendingRecovery.isEmpty }

    func restore() async {
        do {
            book = try store.load()
            devices = book.records
        } catch {
            status = "读取配对记录失败：" + error.localizedDescription
            return
        }

        // A fresh install that still finds records means the Keychain outlived
        // the app: ask before touching them (docs/06 P1-12).
        let firstLaunch = InstallMarker.consumeFirstLaunch()
        if InstallRecovery.shouldOfferRecovery(firstLaunchAfterInstall: firstLaunch, recordCount: devices.count) {
            pendingRecovery = devices
            status = "检测到 \(devices.count) 台旧配对记录"
            return
        }

        guard let first = devices.first(where: { !revoked.contains($0.id) }) else {
            status = devices.isEmpty ? "还没有配对的电脑" : "所有电脑都已移除本机设备"
            return
        }
        await connect(first)
    }

    /// Answers the P1-12 prompt: keep the old credentials, or start clean.
    func resolveRecovery(keep: Bool) async {
        let records = pendingRecovery
        pendingRecovery = []
        guard keep else {
            forgetAll()
            return
        }
        status = "已恢复 \(records.count) 台配对记录"
        if let first = records.first {
            await connect(first)
        }
    }


    // MARK: - List edits

    /// Renames one computer. An empty name is ignored rather than saved.
    func rename(_ record: DeviceRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.displayName else { return }
        book.rename(id: record.id, to: trimmed)
        persist()
    }

    /// Deletes one computer from this device. The computer keeps its own record;
    /// this only forgets the local credential and pinned CA (docs/04).
    func remove(_ record: DeviceRecord) {
        book.remove(id: record.id)
        reachability[record.id] = nil
        revoked.remove(record.id)
        if session?.origin.description == record.origin {
            session = nil
            connection = .idle
        }
        persist()
    }

    /// Makes one computer the default: `restore()` connects to the first entry.
    func moveToFront(_ record: DeviceRecord) {
        book.moveToFront(id: record.id)
        persist()
    }

    private func persist() {
        devices = book.records
        do {
            try store.save(book)
        } catch {
            status = "保存配对记录失败：" + error.localizedDescription
        }
    }

    // MARK: - Reachability

    /// Probes one computer without touching the current session.
    func checkReachability(_ record: DeviceRecord) async {
        reachability[record.id] = .checking
        do {
            let (client, urlSession) = try makeClient(for: record, timeout: 6)
            defer { urlSession.finishTasksAndInvalidate() }
            _ = try await client.probe(deviceToken: record.deviceToken)
            reachability[record.id] = .reachable
        } catch {
            reachability[record.id] = .unreachable(Self.shortReason(error))
        }
    }

    /// Probes every stored computer; the list refreshes as each answer lands.
    func checkAllReachability() async {
        for record in devices {
            await checkReachability(record)
        }
    }

    // MARK: - Connect

    func connect(_ record: DeviceRecord) async {
        session = nil
        log = []
        status = "连接 " + record.displayName + "…"
        connection = .connecting(record.displayName)

        do {
            if record.isExpired() {
                throw MobileAccessFailure.deviceExpired
            }
            let (client, urlSession) = try makeClient(for: record, timeout: 15)
            defer { urlSession.finishTasksAndInvalidate() }

            _ = try await client.probe(deviceToken: record.deviceToken)
            append("probe ok")
            let renewed = try await client.renew(deviceToken: record.deviceToken)
            append("renew ok，会话到期 " + ISO8601DateFormatter().string(from: renewed.sessionExpiresAt))

            let origin = try PairingLink.parse(record.origin).origin
            session = BrowserSession(
                origin: origin,
                evaluator: try evaluator(for: record),
                cookies: SessionCookiePlan.cookies(for: origin, session: renewed),
                deviceToken: record.deviceToken
            )
            reachability[record.id] = .reachable
            revoked.remove(record.id)
            connection = .connected(record.displayName)
            book.markConnected(id: record.id)
            persist()
            status = "已连接 " + record.displayName
        } catch let failure as MobileAccessFailure where failure == .deviceRevoked {
            // P0-09: the computer dropped this device. Stop, say so, and never
            // auto-reconnect to it until it is paired again.
            revoked.insert(record.id)
            connection = .revoked(record.displayName)
            reachability[record.id] = .unreachable("电脑端已移除")
            status = "「" + record.displayName + "」已移除本机设备，请重新配对或删除记录"
            append("revoked: " + record.displayName)
        } catch {
            status = "连接失败：" + error.localizedDescription
            connection = .failed(record.displayName, Self.shortReason(error))
            reachability[record.id] = .unreachable(Self.shortReason(error))
            append("error: " + String(describing: error))
        }
    }

    /// Re-pairing the same computer clears its revoked mark.
    func clearRevoked(_ record: DeviceRecord) {
        revoked.remove(record.id)
        connection = .idle
        status = "已清除「" + record.displayName + "」的移除标记，可重新配对"
    }

    func forgetAll() {
        try? store.delete()
        book = DeviceRecordBook()
        devices = []
        reachability = [:]
        revoked = []
        pendingRecovery = []
        session = nil
        connection = .idle
        status = "已清除本机配对记录"
    }

    // MARK: - Plumbing

    private func evaluator(for record: DeviceRecord) throws -> PinnedTrustEvaluator {
        guard let authority = CertificateAuthority(der: record.certificateAuthority) else {
            throw PairingFlowError.notACertificate
        }
        return PinnedTrustEvaluator(certificateAuthority: authority)
    }

    private func makeClient(for record: DeviceRecord, timeout: TimeInterval) throws -> (MobileAccessClient, URLSession) {
        let origin = try PairingLink.parse(record.origin).origin
        let delegate = PinnedSessionDelegate(evaluator: try evaluator(for: record))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let client = MobileAccessClient(
            origin: origin,
            transport: URLSessionTransport(session: urlSession),
            expectedInstanceId: record.instanceId
        )
        return (client, urlSession)
    }

    /// One line for the list: the error's own text is too long for a row.
    private static func shortReason(_ error: Error) -> String {
        if let failure = error as? MobileAccessFailure {
            return failure.description
        }
        let text = error.localizedDescription
        return text.count > 60 ? String(text.prefix(57)) + "…" : text
    }

    private func append(_ line: String) {
        log.append(line)
    }
}
