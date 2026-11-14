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
        // The page's Enter translation keys off these attributes; record them so
        // a broken newline can be traced to the editor instead of guessed at.
        let probe = """
        (function () {
          var els = document.querySelectorAll('[data-composer-input]');
          var e = els[0];
          return JSON.stringify({
            count: els.length,
            contenteditable: e ? e.getAttribute('contenteditable') : null,
            inputmode: e ? e.getAttribute('inputmode') : null,
            ariaHaspopup: e ? e.getAttribute('aria-haspopup') : null,
            isContentEditable: e ? e.isContentEditable : null,
            native: typeof window.__DSH_MOBILE_NATIVE__,
            keyboard: window.__DSH_MOBILE_KEYBOARD_STATE__ || null
          });
        })();
        """
        host.runInPage(probe) { result in
            Task { @MainActor in
                BridgeLog.shared.append("composer probe", detail: String(describing: result ?? "nil"))
            }
        }
    }

    private func copyAll() {
        let text = "== 设备 ==\n" + DeviceDiagnostics.transcript()
            + "\n\n== 桥日志 ==\n" + bridgeLog.transcript
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
