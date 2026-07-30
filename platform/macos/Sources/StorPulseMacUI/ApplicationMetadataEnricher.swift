@preconcurrency import AppKit
import Foundation
import StorPulseMacAdapter

public struct ApplicationMetadataEnricher: Sendable {
    public init() {}

    public func enrich(_ snapshot: RawSnapshot) -> RawSnapshot {
        let runningApplications = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, ApplicationMetadata(application: $0))
            }
        )
        let processes = snapshot.processes.map { process in
            let metadata = runningApplications[process.identity.pid]
            let parentMetadata = process.parentPID.flatMap { runningApplications[$0] }
            let looksLikeHelper = process.executableName
                .localizedCaseInsensitiveContains("helper")
            let helperMetadata = looksLikeHelper ? (metadata ?? parentMetadata) : metadata
            let helper = looksLikeHelper && helperMetadata?.bundleIdentifier != nil

            return process.applying(
                applicationID: helperMetadata?.bundleIdentifier,
                applicationName: helperMetadata?.displayName,
                isHelper: helper,
                launchedByApplicationID: parentMetadata?.bundleIdentifier
            )
        }
        return snapshot.replacingProcesses(processes)
    }
}

private struct ApplicationMetadata {
    let bundleIdentifier: String?
    let displayName: String?

    init(application: NSRunningApplication) {
        bundleIdentifier = application.bundleIdentifier
        displayName = application.localizedName
    }
}
