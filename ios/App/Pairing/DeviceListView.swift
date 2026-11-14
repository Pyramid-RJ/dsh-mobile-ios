import SwiftUI
import DSHPairing
import DSHDeviceStore

/// The paired computers, with the edits P2 calls for: rename, reorder, delete,
/// and a reachability probe that never touches the current session.
///
/// The list is the only place the stored book is edited; every action goes
/// through `AppModel`, which writes the Keychain immediately (docs/07 P2).
struct DeviceListView: View {
    @ObservedObject var model: AppModel

    @State private var renaming: DeviceRecord?
    @State private var renameText = ""
    @State private var deleting: DeviceRecord?
    @State private var showWeb = false

    var body: some View {
        List {
            Section {
                if model.devices.isEmpty {
                    Text("还没有配对的电脑")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    row(for: device)
                }
            } footer: {
                Text("左滑可重命名或删除；长按可设为默认。删除只清除本机记录，电脑端条目仍在。")
                    .font(.footnote)
            }

            Section("状态") {
                Text(model.status)
                    .font(.footnote)
                ForEach(model.log, id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("设备")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") {
                    Task { await model.checkAllReachability() }
                }
                .disabled(model.devices.isEmpty)
            }
        }
        .navigationDestination(isPresented: $showWeb) {
            if let session = model.session {
                GatewayWebViewScreen(session: session) { revoked in
                    model.markRevoked(origin: revoked.origin.description)
                }
            }
        }
        .alert("重命名", isPresented: renameBinding) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let device = renaming {
                    model.rename(device, to: renameText)
                }
                renaming = nil
            }
        } message: {
            Text("这个名称只存在本机，用于在列表里区分不同的电脑。")
        }
        .alert("删除这台电脑？", isPresented: deleteBinding, presenting: deleting) { device in
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                model.remove(device)
                deleting = nil
            }
        } message: { device in
            Text("将清除本机保存的凭据与固定证书，之后需要重新配对才能连接「\(device.displayName)」。")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for device: DeviceRecord) -> some View {
        Button {
            Task {
                await model.connect(device)
                if model.session != nil {
                    showWeb = true
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.body.weight(.medium))
                    if model.revoked.contains(device.id) {
                        badge("已移除", color: .red)
                    }
                    if device.isExpired() {
                        badge("已过期", color: .red)
                    }
                    if isDefault(device) {
                        badge("默认", color: .blue)
                    }
                }
                Text(host(of: device))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    reachabilityDot(for: device)
                    Text(lastConnectedText(device))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleting = device
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                renaming = device
                renameText = device.displayName
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                renaming = device
                renameText = device.displayName
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                model.moveToFront(device)
            } label: {
                Label("设为默认", systemImage: "arrow.up.to.line")
            }
            Button {
                Task { await model.checkReachability(device) }
            } label: {
                Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
            }
            if model.revoked.contains(device.id) {
                Button {
                    model.clearRevoked(device)
                } label: {
                    Label("清除移除标记", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                deleting = device
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func reachabilityDot(for device: DeviceRecord) -> some View {
        switch model.reachability[device.id] ?? .unknown {
        case .unknown:
            Circle().fill(.secondary).frame(width: 7, height: 7)
            Text("未探测").font(.caption2).foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.mini)
            Text("探测中…").font(.caption2).foregroundStyle(.secondary)
        case .reachable:
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("可达").font(.caption2).foregroundStyle(.green)
        case .unreachable(let reason):
            Circle().fill(.orange).frame(width: 7, height: 7)
            Text(reason).font(.caption2).foregroundStyle(.orange).lineLimit(1)
        }
    }

    // MARK: - Helpers

    private func isDefault(_ device: DeviceRecord) -> Bool {
        model.devices.first?.id == device.id && model.devices.count > 1
    }

    private func host(of device: DeviceRecord) -> String {
        (try? PairingLink.parse(device.origin).origin.description) ?? device.origin
    }

    private func lastConnectedText(_ device: DeviceRecord) -> String {
        guard let date = device.lastConnectedAt else { return "从未连接" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "上次连接 " + formatter.string(from: date)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}
