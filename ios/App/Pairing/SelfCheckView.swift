import SwiftUI
import UIKit
import DSHPairing
import DSHDeviceStore
import DSHTrust

/// The checks that can be answered without a person: stored credentials, their
/// pinned CA, reachability, camera permission, discovery, and what the page sees.
///
/// It exists so the pending-verification list (docs/12) has a place to start:
/// when something fails on device, this screen says which layer is at fault
/// before anyone reads a log.
struct SelfCheckView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var discovery: BonjourDiscovery

    @State private var rows: [Row] = []
    @State private var running = false
    @State private var copied = false
    @State private var address = ""
    @State private var addressResult: String?
    @State private var probing = false

    struct Row: Identifiable {
        enum Level { case pass, warn, fail }

        let id = UUID()
        let title: String
        let detail: String
        let level: Level
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Label("重新自检", systemImage: "arrow.clockwise")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running)
            }

            Section("结果") {
                if rows.isEmpty {
                    Text("点「重新自检」开始")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(for: row.level))
                            .foregroundStyle(color(for: row.level))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("地址连通性") {
                TextField("https://dsh.example.com 或 https://192.168.1.5:3443", text: $address)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    Task {
                        probing = true
                        let result = await RemoteHealthProbe.check(address)
                        addressResult = (result.ok ? "✅ " : "❌ ") + result.detail
                        probing = false
                    }
                } label: {
                    HStack {
                        Label("测试 /mobile-access/health", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if probing { ProgressView() }
                    }
                }
                .disabled(probing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let addressResult {
                    Text(addressResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(addressResult.hasPrefix("✅") ? .green : .orange)
                }
                Text("用系统信任探测，不需要配对；远程隧道地址在配对前可以先在这里确认能不能连通。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("说明") {
                Text("这里只跑不需要人操作的检查。拍照、选文件、扫码、重装恢复这类需要真机交互的项，见 docs/12 的清单。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("自检")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copied ? "已复制" : "复制报告") { copyReport() }
                    .disabled(rows.isEmpty)
            }
        }
        .task { await run() }
    }

    // MARK: - Checks

    private func run() async {
        running = true
        defer { running = false }
        var results: [Row] = []

        results.append(Row(
            title: "已配对电脑",
            detail: model.devices.isEmpty ? "没有记录" : "\(model.devices.count) 台",
            level: model.devices.isEmpty ? .warn : .pass
        ))

        for record in model.devices {
            results.append(contentsOf: healthRows(for: record))
        }

        for record in model.devices {
            await model.checkReachability(record)
            switch model.reachability[record.id] ?? .unknown {
            case .reachable:
                results.append(Row(title: "可达 · \(record.displayName)", detail: record.origin, level: .pass))
            case .unreachable(let reason):
                results.append(Row(title: "不可达 · \(record.displayName)", detail: reason, level: .warn))
            case .checking, .unknown:
                results.append(Row(title: "未探测 · \(record.displayName)", detail: record.origin, level: .warn))
            }
        }

        let camera = CameraCapture.cameraStatus()
        results.append(Row(
            title: "相机权限",
            detail: CameraCapture.statusName(camera) + (CameraCapture.isAvailable ? "，设备有相机" : "，设备没有相机"),
            level: camera == .authorized ? .pass : .warn
        ))

        results.append(Row(
            title: "局域网发现",
            detail: discovery.hosts.isEmpty ? discovery.state : "\(discovery.hosts.count) 台 · \(discovery.state)",
            level: discovery.hosts.isEmpty ? .warn : .pass
        ))

        if let page = await pageReport() {
            results.append(page)
        } else {
            results.append(Row(title: "页面", detail: "当前没有打开的页面", level: .warn))
        }

        rows = results
    }

    private func healthRows(for record: DeviceRecord) -> [Row] {
        let fingerprint = record.certificateAuthority
            .flatMap { CertificateAuthority(der: $0) }?.sha256Hex
        let issues = DeviceHealth.issues(record: record, caFingerprint: fingerprint)
        guard !issues.isEmpty else {
            return [Row(title: "凭据 · \(record.displayName)", detail: "有效期与 CA 指纹正常", level: .pass)]
        }
        return issues.map { issue in
            Row(
                title: "凭据 · \(record.displayName)",
                detail: issue.description,
                level: .fail
            )
        }
    }

    private func pageReport() async -> Row? {
        guard let host = BridgeHostRegistry.shared.current else { return nil }
        let script = """
        (function () {
          var meta = document.querySelector('meta[name="dsh-mobile-gateway"]');
          return [
            'frontend=' + String(window.__DSH_MOBILE_FRONTEND__),
            'gateway=' + (meta ? meta.getAttribute('content') : 'none'),
            'bridge=' + (typeof window.__DSH_MOBILE_NATIVE__)
          ].join(' | ');
        })();
        """
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            host.runInPage(script) { result in
                continuation.resume(returning: result as? String)
            }
        }
        guard let value else {
            return Row(title: "页面", detail: "无法读取页面标记", level: .warn)
        }
        let dedicated = value.contains("frontend=dedicated")
        return Row(title: "页面", detail: value, level: dedicated ? .pass : .warn)
    }

    // MARK: - Presentation

    private func symbol(for level: Row.Level) -> String {
        switch level {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        }
    }

    private func color(for level: Row.Level) -> Color {
        switch level {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }

    private func copyReport() {
        let text = rows.map { row in
            let mark: String
            switch row.level {
            case .pass: mark = "[OK]"
            case .warn: mark = "[!]"
            case .fail: mark = "[X]"
            }
            return mark + " " + row.title + " — " + row.detail
        }
        .joined(separator: "\n")
        UIPasteboard.general.string = "== 自检 ==\n" + text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
