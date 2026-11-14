import Foundation
import Network
import DSHDiscovery

/// Browses `_dsh-mobile._tcp` on the local network (docs/00 S-4, docs/07 P5).
///
/// Discovery is a convenience, not a pairing path: the announcement carries no
/// token, so a computer found here can be connected to only when it is already
/// paired. Anything that does not match the contract is dropped and recorded in
/// the log instead of being shown.
@MainActor
final class BonjourDiscovery: ObservableObject {
    struct DiscoveredHost: Identifiable, Equatable {
        /// The gateway instance id, which is also the pinned CA fingerprint.
        let id: String
        let name: String
        let origin: String
    }

    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var state = "未开始"
    @Published private(set) var log: [String] = []

    private var browser: NWBrowser?

    static let serviceType = "_dsh-mobile._tcp"

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.apply(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results)
            }
        }
        self.browser = browser
        state = "正在搜索附近电脑…"
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
        state = "已停止搜索"
    }

    private func apply(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            self.state = hosts.isEmpty ? "正在搜索附近电脑…" : "找到 \(hosts.count) 台"
        case .failed(let error):
            self.state = "搜索失败：" + error.localizedDescription
            append("browser failed: " + error.localizedDescription)
        case .cancelled:
            self.state = "已停止搜索"
        default:
            break
        }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredHost] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            guard case let .bonjour(record) = result.metadata else { continue }
            do {
                let announcement = try DiscoveryAnnouncement.parse(txt: record.dictionary)
                found.append(DiscoveredHost(
                    id: announcement.instanceId,
                    name: announcement.deviceName,
                    origin: announcement.origin
                ))
            } catch {
                // A computer that does not speak the contract is not an error,
                // but it should be visible while diagnosing discovery.
                append("ignored " + name + ": " + String(describing: error))
            }
        }
        hosts = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !hosts.isEmpty {
            state = "找到 \(hosts.count) 台"
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 40 {
            log.removeFirst(log.count - 40)
        }
    }
}
