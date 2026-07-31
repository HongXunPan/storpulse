import SwiftUI

struct ObservationSessionResultView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var lastSavedName: String

    let record: ObservationRecordSummary
    let historyEnabled: Bool
    let showsDoneButton: Bool
    let onRename: (String) -> Void

    init(
        record: ObservationRecordSummary,
        historyEnabled: Bool,
        showsDoneButton: Bool = true,
        onRename: @escaping (String) -> Void
    ) {
        self.record = record
        self.historyEnabled = historyEnabled
        self.showsDoneButton = showsDoneButton
        self.onRename = onRename
        _name = State(initialValue: record.name)
        _lastSavedName = State(initialValue: record.name)
    }

    var body: some View {
        Form {
            Section("记录名称") {
                TextField("记录名称", text: $name)
                    .onSubmit(saveName)
                Text("结束后可直接修改；名称只保存在本机，不进入隐私摘要导出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本次区间") {
                LabeledContent(
                    "持续时长",
                    value: IOPresentation.duration(
                        milliseconds: record.durationMilliseconds
                    )
                )
                LabeledContent(
                    "读取总量",
                    value: IOPresentation.bytes(record.readBytes)
                )
                LabeledContent(
                    "写入总量",
                    value: IOPresentation.bytes(record.writeBytes)
                )
                LabeledContent(
                    "可信状态",
                    value: completenessTitle
                )
            }

            Section("峰值速度") {
                LabeledContent(
                    "读取",
                    value: IOPresentation.rate(
                        record.peak.readBytesPerSecond
                    )
                )
                LabeledContent(
                    "写入",
                    value: IOPresentation.rate(
                        record.peak.writeBytesPerSecond
                    )
                )
            }

            if !record.topApplications.isEmpty {
                Section("主要应用与服务") {
                    ForEach(record.topApplications.prefix(5)) { application in
                        LabeledContent(application.displayName) {
                            if let readBytes = application.readBytes,
                               let writeBytes = application.writeBytes
                            {
                                Text(
                                    "读 \(IOPresentation.bytes(readBytes)) · 写 \(IOPresentation.bytes(writeBytes))"
                                )
                                .monospacedDigit()
                            } else {
                                Text("应用标识")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                if historyEnabled {
                    Label(persistenceTitle, systemImage: persistenceSymbol)
                        .foregroundStyle(.secondary)
                } else {
                    Label(persistenceTitle, systemImage: persistenceSymbol)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("区间记录结果")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        saveName()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 430)
        .onDisappear(perform: saveName)
    }

    private var persistenceTitle: String {
        historyEnabled
            ? "历史已启用，本次记录按设置保存在本机"
            : "已保留到本次运行；退出 StorPulse 后清除"
    }

    private var persistenceSymbol: String {
        historyEnabled ? "checkmark.circle" : "info.circle"
    }

    private var completenessTitle: String {
        switch record.completeness {
        case "complete":
            "完整"
        case "partial":
            "部分受限"
        case "restricted":
            "受限"
        case "unsupported":
            "不支持"
        default:
            "未知"
        }
    }

    private func saveName() {
        let normalized = ObservationRecord.normalizedName(
            name,
            fallback: record.name
        )
        name = normalized
        guard normalized != lastSavedName else { return }
        lastSavedName = normalized
        onRename(normalized)
    }
}
