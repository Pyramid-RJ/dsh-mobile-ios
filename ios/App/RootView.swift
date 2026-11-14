import SwiftUI
import UIKit
import DSHPairing
import DSHDeviceStore

/// Phase P0 screen. It proves the app target builds, links the DSHPairing
/// package and can parse what the computer prints. Pairing, trust and the web
/// view arrive in P1; nothing here touches the network yet.
struct RootView: View {
    @State private var input = ""
    @State private var result = "粘贴配对链接或配对键后点解析。"
    @State private var parsedGateway: String?
    @State private var parsedInstance: String?
    @StateObject private var pairing = PairingCoordinator()
    @StateObject private var model = AppModel()
    @StateObject private var discovery = BonjourDiscovery()
    @State private var showsScanner = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return version + " (" + build + ")"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "?"
    }

    /// The status row used to say "未实现（P1）" long after P1 shipped.
    private var connectionSummary: String {
        switch model.connection {
        case .idle:
            return model.devices.isEmpty ? "未配对" : "未连接"
        case .connecting(let name):
            return "连接 " + name + "…"
        case .connected(let name):
            return "已连接 " + name
        case .revoked(let name):
            return name + " 已被移除"
        case .failed(_, let reason):
            return "连接失败：" + reason
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("状态") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("Bundle ID", value: bundleIdentifier)
                    LabeledContent("系统", value: UIDevice.current.systemVersion)
                    LabeledContent("配对与网页", value: connectionSummary)
                }

                if case .revoked(let name) = model.connection {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("「\(name)」已移除本机设备", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text("电脑端不再接受这台手机。请重新配对，或在设备列表里删除这条记录。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("解析配对输入") {
                    TextField(
                        "https://host:3443/mobile-access/pair#token=…",
                        text: $input,
                        axis: .vertical
                    )
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    // Two buttons in one Form row become a single tap target
                    // unless each carries a borderless style.
                    HStack {
                        Button("解析") { parse() }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button {
                            showsScanner = true
                        } label: {
                            Label("扫码", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderless)
                        .disabled(pairing.isPairing)
                    }
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("已配对") {
                    if model.isAwaitingRecoveryDecision {
                        // P1-12: the Keychain outlived the app; ask before using it.
                        VStack(alignment: .leading, spacing: 8) {
                            Label("检测到 \(model.pendingRecovery.count) 台旧配对记录", systemImage: "questionmark.folder")
                                .font(.footnote.weight(.semibold))
                            Text("这些记录来自上一次安装。恢复后可以直接连接，清除则需要重新配对。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("恢复") {
                                    Task { await model.resolveRecovery(keep: true) }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("清除", role: .destructive) {
                                    Task { await model.resolveRecovery(keep: false) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    if model.devices.isEmpty {
                        Text("还没有配对的电脑")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            DeviceListView(model: model)
                        } label: {
                            LabeledContent("设备", value: "\(model.devices.count) 台")
                        }
                    }

                    Text(model.status)
                        .font(.footnote)

                    // One row only: right after pairing both sessions point at the
                    // same host, and two identical "打开" rows read as two devices.
                    if let session = model.session ?? pairing.session {
                        NavigationLink("打开 \(session.origin.host)") {
                            GatewayWebViewScreen(session: session) { revoked in
                                model.markRevoked(origin: revoked.origin.description)
                            }
                        }
                    }
                }

                if !discovery.hosts.isEmpty || discovery.state != "未开始" {
                    Section("附近的电脑") {
                        ForEach(discovery.hosts) { host in
                            Button {
                                connect(discovered: host)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(host.name)
                                        if isPaired(host) == false {
                                            Text("未配对")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(host.origin)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(discovery.state)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(discovery.log.suffix(3), id: \.self) { line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("配对") {
                    Button("配对并打开") {
                        Task {
                            await pairing.pair(input: input)
                            adoptPairingIfSucceeded()
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text(pairing.status)
                        .font(.footnote)

                    ForEach(pairing.log, id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let session = pairing.session {
                        NavigationLink("打开 DSH 页面") {
                            GatewayWebViewScreen(session: session)
                        }
                    }
                }

                Section("诊断") {
                    NavigationLink("S-1 探针：WKWebView + 固定私有 CA") {
                        S1ProbeView(initialGateway: parsedGateway ?? "", expectedInstanceId: parsedInstance)
                    }
                    Text("通知与后台事件流不提供：免费签名没有 APNs。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DSH Mobile")
            .task { await model.restore() }
            .task { discovery.start() }
            .onDisappear { discovery.stop() }
            .sheet(isPresented: $showsScanner) {
                NavigationStack {
                    QRScannerView { code in
                        showsScanner = false
                        acceptScanned(code)
                    }
                }
            }
        }
    }

    /// A scanned pairing code goes through the same path as a pasted one, and
    /// pairs straight away: US-3 is "scan and you are in".
    ///
    /// A bare origin is a valid *paste* (F-1.1 accepts it), but it is not a
    /// pairing code: scanning a random URL must not overwrite the field or send
    /// the gateway a request that can only fail.
    private func acceptScanned(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPairingCode(trimmed) else {
            result = "这不是 DSH 配对码（缺少配对 token），请对准电脑上的二维码。"
            return
        }
        input = trimmed
        parse()
        Task {
            await pairing.pair(input: trimmed)
            adoptPairingIfSucceeded()
        }
    }

    private func isPaired(_ host: BonjourDiscovery.DiscoveredHost) -> Bool {
        model.devices.contains { $0.instanceId == host.id }
    }

    /// A discovered computer can only be connected to when it is already paired:
    /// the announcement carries no pairing token.
    private func connect(discovered host: BonjourDiscovery.DiscoveredHost) {
        guard let record = model.devices.first(where: { $0.instanceId == host.id }) else {
            result = "「\(host.name)」还没有配对，请扫描它的配对二维码。"
            return
        }
        Task { await model.connect(record) }
    }

    /// A finished pairing wrote a fresh record: let the device list pick it up
    /// and drop any "removed" mark the same computer carried.
    private func adoptPairingIfSucceeded() {
        guard let session = pairing.session else { return }
        model.adoptPairedGateway(origin: session.origin.description)
    }

    /// True only for something that can actually pair: a `dsh1./dsh2.` key, or a
    /// pairing link that carries a token.
    private func isPairingCode(_ text: String) -> Bool {
        if text.hasPrefix("dsh1.") || text.hasPrefix("dsh2.") {
            return (try? PairingKey.parse(text)) != nil
        }
        return (try? PairingLink.parse(text))?.token != nil
    }

    private func parse() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            result = "输入为空。"
            return
        }

        if trimmed.hasPrefix("dsh1.") || trimmed.hasPrefix("dsh2.") {
            do {
                let key = try PairingKey.parse(trimmed)
                let pinning = key.requiresPinnedCertificateAuthority ? "是" : "否"
                result = "配对键 \(key.kind.rawValue)：实例 \(String(key.instanceId.prefix(12)))…，需要固定 CA：\(pinning)"
                parsedGateway = nil
                parsedInstance = key.instanceId
            } catch {
                result = "配对键无效：\(error)"
                parsedGateway = nil
                parsedInstance = nil
            }
            return
        }

        do {
            let link = try PairingLink.parse(trimmed)
            let token = link.token == nil ? "无" : "有"
            let instance = link.instanceId.map { String($0.prefix(12)) + "…" } ?? "无"
            result = "Origin \(link.origin.description)，配对 token：\(token)，CA instance：\(instance)"
            parsedGateway = link.origin.description
            parsedInstance = link.instanceId
        } catch {
            result = "链接无效：\(error)"
            parsedGateway = nil
            parsedInstance = nil
        }
    }
}
