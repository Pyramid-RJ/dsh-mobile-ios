import SwiftUI
import UIKit
import DSHBridge

/// What the page told the bridge, plus the device facts behind a failure.
///
/// This screen exists because the only way to see *why* a capture failed used to
/// be Console.app on a Mac (docs/09 §2). Everything here can be copied out as
/// plain text and pasted back into a report.
struct BridgeLogScreen: View {
    @ObservedObject private var bridgeLog = BridgeLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var renewResult: String?
    @State private var pageText: String?

    var body: some View {
        NavigationStack {
            List {
                Section("设备诊断") {
                    ForEach(DeviceDiagnostics.lines(), id: \.key) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(item.value)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("页面内容") {
                    Button {
                        Task { await readPageText() }
                    } label: {
                        Label("读取页面当前内容", systemImage: "doc.text.magnifyingglass")
                    }
                    if let pageText {
                        Text(pageText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("隧道/远程连接下页面空白时，用它看页面到底渲染了什么。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("续期取消（B7 / P0-18）") {
                    Button {
                        Task { await probeRenewCancel() }
                    } label: {
                        Label("发起续期并在 50 ms 后取消", systemImage: "arrow.uturn.backward.circle")
                    }
                    if let renewResult {
                        Text(renewResult)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("应出现 auth.renew cancelled 与 reply failed cancelled；若显示 reply ok，说明续期在 50 ms 内就完成了，再点一次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("桥日志") {
                    if bridgeLog.entries.isEmpty {
                        Text("还没有记录：页面加载后会出现 bridge.ready")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bridgeLog.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.line)
                                .font(.caption2.monospaced())
                            if let detail = entry.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("桥日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "已复制" : "复制全部") { copyAll() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await askBridgeForDiagnostics() }
        }
    }

    /// The host answers `host.diagnostics`; the reply is logged like any other,
    /// so the same facts end up in the transcript.
    private func askBridgeForDiagnostics() async {
        guard let host = BridgeHostRegistry.shared.current else {
            BridgeLog.shared.append("diagnostics skipped", detail: "no web view is on screen")
            return
        }
        let reply = await host.diagnose()
        if !reply.ok {
            BridgeLog.shared.append("diagnostics failed", detail: reply.message)
        }
    }

    /// Reads what the page actually rendered, for the "connected but empty" case.
    private func readPageText() async {
        guard let host = BridgeHostRegistry.shared.current else {
            pageText = "当前没有打开的页面"
            return
        }
        let script = """
        (function () {
          var text = (document.body && document.body.innerText ? document.body.innerText : '')
            .replace(/\\s+/g, ' ').trim();
          return [
            'title=' + document.title,
            'path=' + location.pathname,
            'chars=' + text.length,
            'text=' + text.slice(0, 240)
          ].join(' | ');
        })();
        """
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            host.runInPage(script) { result in
                continuation.resume(returning: result as? String)
            }
        }
        pageText = value ?? "读取失败"
        BridgeLog.shared.append("page text", detail: pageText)
    }

    /// B7 lives here rather than on the self-check screen: the probe needs an
    /// open page, and this sheet is only reachable from one.
    private func probeRenewCancel() async {
        guard let host = BridgeHostRegistry.shared.current else {
            renewResult = "当前没有打开的页面"
            return
        }
        let script = """
        (function () {
          if (!window.__DSH_MOBILE_NATIVE__) { return 'no-bridge'; }
          var controller = new AbortController();
          window.__DSH_MOBILE_NATIVE__.invoke('auth.renew', {}, { signal: controller.signal })
            .catch(function () {});
          setTimeout(function () { controller.abort(); }, 50);
          return 'started';
        })();
        """
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            host.runInPage(script) { result in
                continuation.resume(returning: result as? String)
            }
        }
        renewResult = "已发起（" + (started ?? "nil") + "），看下面的桥日志"
    }

    private func copyAll() {
        let text = "== 设备 ==\n" + DeviceDiagnostics.transcript()
            + "\n\n== 桥日志 ==\n" + bridgeLog.transcript
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
