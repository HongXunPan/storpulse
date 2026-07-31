import StorPulseMacAdapter
@testable import StorPulseMacUI
import Testing

@Test("列头指标支持升降序和稳定默认值")
func applicationHeaderSorting() {
    let active = applicationFixture(
        id: "com.example.active",
        displayName: "Active",
        currentRead: 4_096,
        currentWrite: 2_048
    )
    let idle = applicationFixture(
        id: "com.example.idle",
        displayName: "Idle",
        currentRead: 1,
        currentWrite: 1
    )
    let applications = [idle, active]

    #expect(
        IOPresentation.sorted(
            applications,
            by: ApplicationSortOrder(
                criterion: .current,
                ascending: false
            )
        ).first?.applicationID == "com.example.active"
    )
    #expect(
        IOPresentation.sorted(
            applications,
            by: ApplicationSortOrder(
                criterion: .current,
                ascending: true
            )
        ).first?.applicationID == "com.example.idle"
    )
    #expect(
        IOPresentation.sorted(
            applications,
            by: ApplicationSortOrder(
                criterion: .application,
                ascending: true
            )
        ).map(\.applicationID) == [
            "com.example.active",
            "com.example.idle",
        ]
    )
    #expect(ApplicationSortOrder.defaultOrder.criterion == .current)
    #expect(!ApplicationSortOrder.defaultOrder.ascending)
}

@Test("应用名搜索忽略首尾空白和英文大小写")
func applicationNameFiltering() {
    let applications = [
        applicationFixture(
            id: "com.example.editor",
            displayName: "Editor"
        ),
        applicationFixture(
            id: "com.example.archive",
            displayName: "Archive Utility"
        ),
    ]

    #expect(
        IOPresentation.filtered(
            applications,
            matching: "  ARCHIVE  "
        ).map(\.applicationID) == ["com.example.archive"]
    )
    #expect(
        IOPresentation.filtered(
            applications,
            matching: "不存在"
        ).isEmpty
    )
    #expect(
        IOPresentation.filtered(
            applications,
            matching: "   "
        ).count == applications.count
    )
}

private func applicationFixture(
    id: String,
    displayName: String,
    currentRead: Double = 0,
    currentWrite: Double = 0
) -> RealtimeApplication {
    RealtimeApplication(
        applicationID: id,
        displayName: displayName,
        processCount: 1,
        helperCount: 0,
        current: IORate(
            readBytesPerSecond: currentRead,
            writeBytesPerSecond: currentWrite
        ),
        averageLastMinute: nil,
        runReadBytes: 0,
        runWriteBytes: 0,
        continuousIODurationMilliseconds: 0,
        processIdentities: []
    )
}
