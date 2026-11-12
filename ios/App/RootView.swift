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

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return version + " (" + build + ")"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "?"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("状态") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("Bundle ID", value: bundleIdentifier)
                    LabeledContent("系统", value: UIDevice.current.systemVersion)
                    LabeledContent("配对与网页", value: "未实现（P1）")
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

                    Button("解析") { parse() }
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("已配对") {
                    if model.devices.isEmpty {
                        Text("还没有配对的电脑")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.devices) { device in
                            Button(device.displayName) {
                                Task { await model.connect(device) }
                            }
                        }
                    }

                    Text(model.status)
                        .font(.footnote)

                    if let session = model.session {
                        NavigationLink("打开 (session.origin.host)") {
                            GatewayWebViewScreen(session: session)
                        }
                    }

                    if let session = pairing.session {
                        NavigationLink("打开 \(session.origin.host)（刚配对）") {
                            GatewayWebViewScreen(session: session)
                        }
                    }
                }

                Section("配对（P1）") {
                    Button("配对并打开") {
                        Task { await pairing.pair(input: input) }
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

                Section("P0 探针") {
                    NavigationLink("S-1：WKWebView + 固定私有 CA") {
                        S1ProbeView(initialGateway: parsedGateway ?? "", expectedInstanceId: parsedInstance)
                    }
                }

                Section("下一步") {
                    Text("S-1：验证 WKWebView 能否用固定私有 CA 加载自签页面。")
                    Text("这一步决定局域网路径是否成立，失败则退回纯浏览器壳。")
                }

                Section("本版本不提供") {
                    Text("通知（免费签名无 APNs）")
                    Text("后台事件流")
                }
            }
            .navigationTitle("DSH Mobile")
            .task { await model.restore() }
        }
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
