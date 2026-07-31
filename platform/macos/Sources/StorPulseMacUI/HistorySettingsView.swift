import SwiftUI

public struct HistorySettingsView: View {
    @ObservedObject private var model: HistoryViewModel
    @State private var confirmingClear = false

    public init(model: HistoryViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            historySection
            reminderSection
            storageSection
            messageSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存设置") {
                    Task { await model.save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || invalidEnabledReminder)
            }
        }
        .confirmationDialog(
            "清理所有本机历史？",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("清理历史", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作只删除 StorPulse 的分钟摘要、活动和区间记录，不影响其他应用。")
        }
    }

    private var historySection: some View {
        Section("低写入历史") {
            Toggle("启用历史", isOn: $model.settings.historyEnabled)
            Text("关闭时不创建数据库，也不会周期性写入磁盘。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("保留时间", selection: $model.settings.retention) {
                ForEach(RetentionPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .disabled(!model.settings.historyEnabled)
        }
    }

    private var reminderSection: some View {
        Section("持续 I/O 提醒") {
            Toggle("启用提醒", isOn: $model.settings.reminder.enabled)
            numericField(
                "读取阈值（MB/秒）",
                value: megabytesBinding(\HistorySettings.reminder.readThresholdBytesPerSecond)
            )
            numericField(
                "写入阈值（MB/秒）",
                value: megabytesBinding(\HistorySettings.reminder.writeThresholdBytesPerSecond)
            )
            numericField(
                "最短持续时间（秒）",
                value: $model.settings.reminder.minimumDurationSeconds
            )
            numericField(
                "冷却时间（秒）",
                value: $model.settings.reminder.cooldownSeconds
            )
            Text("StorPulse 不会自动填入推测阈值；四项都由你确认后才能启用。")
                .font(.caption)
                .foregroundStyle(invalidEnabledReminder ? .red : .secondary)
        }
    }

    private var storageSection: some View {
        Section("本机数据") {
            LabeledContent("分钟摘要", value: "\(model.counts.minuteBuckets)")
            LabeledContent("已结束活动", value: "\(model.counts.activities)")
            LabeledContent("区间记录", value: "\(model.counts.observationSessions)")
            HStack {
                Button("导出隐私摘要") {
                    Task { await model.exportHistory() }
                }
                .disabled(!model.settings.historyEnabled || model.isWorking)
                Spacer()
                Button("清理历史", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(!model.settings.historyEnabled || model.isWorking)
            }
        }
    }

    @ViewBuilder
    private var messageSection: some View {
        if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } else if let status = model.statusMessage {
            Section {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var invalidEnabledReminder: Bool {
        model.settings.reminder.enabled
            && !model.settings.reminder.hasExplicitThresholds
    }

    private func numericField(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0 ... 2)))
            .textFieldStyle(.roundedBorder)
            .disabled(!model.settings.reminder.enabled)
    }

    private func megabytesBinding(
        _ keyPath: WritableKeyPath<HistorySettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: keyPath] / 1_000_000 },
            set: { model.settings[keyPath: keyPath] = max(0, $0) * 1_000_000 }
        )
    }
}
