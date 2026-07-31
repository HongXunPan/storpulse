import SwiftUI

struct ObservationRecordsView: View {
    @ObservedObject var monitor: RealtimeMonitor
    @ObservedObject var historyViewModel: HistoryViewModel

    var body: some View {
        Group {
            if currentRunRecords.isEmpty && persistedRecords.isEmpty {
                ContentUnavailableView(
                    "还没有区间记录",
                    systemImage: "record.circle",
                    description: Text("在实时观察中开始记录，结束后会出现在这里。")
                )
            } else {
                List {
                    if !currentRunRecords.isEmpty {
                        Section("本次运行") {
                            ForEach(currentRunRecords) { record in
                                recordLink(record, isCurrentRun: true)
                            }
                        }
                    }
                    if historyViewModel.settings.historyEnabled,
                       !persistedRecords.isEmpty
                    {
                        Section("本机历史") {
                            ForEach(persistedRecords) { record in
                                recordLink(record, isCurrentRun: false)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .safeAreaInset(edge: .bottom) {
            persistenceFooter
        }
        .task {
            await historyViewModel.refreshHistory()
        }
    }

    private var currentRunRecords: [ObservationRecordSummary] {
        monitor.observationRecords.map(\.summary)
    }

    private var persistedRecords: [ObservationRecordSummary] {
        let currentIDs = Set(currentRunRecords.map(\.id))
        return historyViewModel.observationRecords.filter {
            !currentIDs.contains($0.id)
        }
    }

    private var persistenceFooter: some View {
        HStack {
            Label(
                historyViewModel.settings.historyEnabled
                    ? "历史已启用，区间记录按保留设置存放在本机"
                    : "历史未启用，本次运行记录会在退出 StorPulse 后清除",
                systemImage: historyViewModel.settings.historyEnabled
                    ? "checkmark.circle"
                    : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(
                historyViewModel.settings.historyEnabled
                    ? Color.secondary
                    : Color.orange
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func recordLink(
        _ record: ObservationRecordSummary,
        isCurrentRun: Bool
    ) -> some View {
        NavigationLink {
            ObservationSessionResultView(
                record: record,
                historyEnabled: historyViewModel.settings.historyEnabled,
                showsDoneButton: false,
                onRename: { name in
                    rename(record, isCurrentRun: isCurrentRun, to: name)
                }
            )
        } label: {
            ObservationRecordRow(record: record)
        }
    }

    private func rename(
        _ record: ObservationRecordSummary,
        isCurrentRun: Bool,
        to name: String
    ) {
        Task {
            if isCurrentRun {
                _ = await monitor.renameObservationRecord(
                    sessionID: record.id,
                    name: name
                )
                await historyViewModel.refreshHistory()
            } else {
                await historyViewModel.renameObservationRecord(
                    sessionID: record.id,
                    name: name
                )
            }
        }
    }
}

private struct ObservationRecordRow: View {
    let record: ObservationRecordSummary

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(Self.dateTitle(record.endedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(
                    "读 \(IOPresentation.bytes(record.readBytes)) · 写 \(IOPresentation.bytes(record.writeBytes))"
                )
                .font(.callout.monospacedDigit())
                Text(
                    IOPresentation.duration(
                        milliseconds: record.durationMilliseconds
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private static func dateTitle(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            return value
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
