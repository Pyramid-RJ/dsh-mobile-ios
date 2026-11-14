import SwiftUI
import UIKit

/// The manual verification list, markable on the phone (docs/12).
struct ChecklistView: View {
    @State private var statuses: [String: VerificationChecklist.Status] = [:]
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("自检页跑自动项；这里是人要动手的项。点开一条看步骤与判定，测完标通过或失败。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(VerificationChecklist.items) { item in
                NavigationLink {
                    detail(item)
                } label: {
                    HStack {
                        statusDot(item.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.id + " · " + item.title)
                            Text(statusLabel(item.id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("验收清单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copied ? "已复制" : "复制报告") { copyReport() }
            }
        }
        .onAppear(perform: reload)
    }

    private func detail(_ item: VerificationChecklist.Item) -> some View {
        Form {
            Section("步骤") {
                ForEach(Array(item.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). " + step)
                        .font(.callout)
                }
            }
            Section("判定") {
                Text(item.criterion)
                    .font(.callout)
            }
            Section("结果") {
                Picker("状态", selection: binding(for: item.id)) {
                    ForEach(VerificationChecklist.Status.allCases, id: \.self) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(item.id)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for id: String) -> Binding<VerificationChecklist.Status> {
        Binding(
            get: { statuses[id] ?? .untested },
            set: { newValue in
                statuses[id] = newValue
                VerificationChecklist.set(newValue, for: id)
            }
        )
    }

    private func reload() {
        var table: [String: VerificationChecklist.Status] = [:]
        for item in VerificationChecklist.items {
            table[item.id] = VerificationChecklist.status(for: item.id)
        }
        statuses = table
    }

    @ViewBuilder
    private func statusDot(_ id: String) -> some View {
        switch statuses[id] ?? .untested {
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .untested:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ id: String) -> String {
        (statuses[id] ?? .untested).label
    }

    private func copyReport() {
        UIPasteboard.general.string = VerificationChecklist.report()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
