struct RealtimeApplicationTableRow: Equatable, Identifiable {
    let id: String
    let displayName: String
    let processSummary: String
    let currentRead: String
    let currentWrite: String
    let recentRead: String
    let recentWrite: String
    let totalRead: String
    let totalWrite: String
    let duration: String

    init(application: RealtimeApplication, ratesAreTrustworthy: Bool) {
        id = application.applicationID
        displayName = application.displayName
        if application.helperCount == 0 {
            processSummary = "\(application.processCount) 个进程"
        } else {
            processSummary =
                "\(application.processCount) 个进程 · \(application.helperCount) 个 Helper"
        }

        let current = ratesAreTrustworthy ? application.current : nil
        currentRead = "读 \(IOPresentation.rate(current?.readBytesPerSecond))"
        currentWrite = "写 \(IOPresentation.rate(current?.writeBytesPerSecond))"
        recentRead =
            "读 \(IOPresentation.rate(application.averageLastMinute?.readBytesPerSecond))"
        recentWrite =
            "写 \(IOPresentation.rate(application.averageLastMinute?.writeBytesPerSecond))"
        totalRead = "读 \(IOPresentation.bytes(application.runReadBytes))"
        totalWrite = "写 \(IOPresentation.bytes(application.runWriteBytes))"
        duration = IOPresentation.duration(
            milliseconds: application.continuousIODurationMilliseconds
        )
    }
}

struct RealtimeApplicationTableSnapshot: Equatable {
    let rows: [RealtimeApplicationTableRow]

    init(
        applications: [RealtimeApplication],
        ratesAreTrustworthy: Bool
    ) {
        rows = applications.map {
            RealtimeApplicationTableRow(
                application: $0,
                ratesAreTrustworthy: ratesAreTrustworthy
            )
        }
    }

    func index(of applicationID: String?) -> Int? {
        guard let applicationID else { return nil }
        return rows.firstIndex { $0.id == applicationID }
    }
}
