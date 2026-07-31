@preconcurrency import AppKit
import Foundation
import StorPulseMacAdapter

public struct ApplicationMetadataEnricher: Sendable {
    public init() {}

    public func enrich(_ snapshot: RawSnapshot) -> RawSnapshot {
        let entries = NSWorkspace.shared.runningApplications.compactMap {
            application -> (
                processIdentifier: pid_t,
                metadata: ApplicationMetadata
            )? in
            let processIdentifier = application.processIdentifier
            guard processIdentifier > 0, !application.isTerminated else {
                return nil
            }
            return (
                processIdentifier,
                ApplicationMetadata(application: application)
            )
        }
        let runningApplications = Self.metadataIndex(entries)
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

    static func metadataIndex(
        _ entries: [(
            processIdentifier: pid_t,
            metadata: ApplicationMetadata
        )]
    ) -> [pid_t: ApplicationMetadata] {
        let validEntries = entries.compactMap {
            entry -> (pid_t, ApplicationMetadata)? in
            guard entry.processIdentifier > 0 else { return nil }
            return (entry.processIdentifier, entry.metadata)
        }
        return Dictionary(
            validEntries,
            uniquingKeysWith: ApplicationMetadata.preferred
        )
    }
}

struct ApplicationMetadata: Equatable {
    let bundleIdentifier: String?
    let displayName: String?

    init(bundleIdentifier: String?, displayName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    init(application: NSRunningApplication) {
        bundleIdentifier = application.bundleIdentifier
        let bundleURL = application.bundleURL
        let serviceDisplayName = Self.isServiceBundle(bundleURL)
            ? Self.localizedBundleDisplayName(at: bundleURL)
            : nil
        displayName = Self.resolvedDisplayName(
            localizedName: application.localizedName,
            bundleURL: bundleURL,
            localizedBundleDisplayName: serviceDisplayName
        )
    }

    static func preferred(
        _ existing: ApplicationMetadata,
        _ candidate: ApplicationMetadata
    ) -> ApplicationMetadata {
        candidate.completenessScore > existing.completenessScore
            ? candidate
            : existing
    }

    static func resolvedDisplayName(
        localizedName: String?,
        bundleURL: URL?,
        localizedBundleDisplayName: String?
    ) -> String? {
        if isServiceBundle(bundleURL) {
            return normalizedName(localizedBundleDisplayName)
                ?? normalizedName(localizedName)
        }
        return normalizedName(localizedName)
    }

    private static func isServiceBundle(_ bundleURL: URL?) -> Bool {
        bundleURL?.pathExtension.caseInsensitiveCompare("xpc") == .orderedSame
    }

    private static func localizedBundleDisplayName(at bundleURL: URL?) -> String? {
        guard
            let bundleURL,
            let bundle = Bundle(url: bundleURL),
            let declaredName = (
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName")
            ) as? String
        else {
            return nil
        }
        return bundle.localizedString(
            forKey: declaredName,
            value: declaredName,
            table: nil
        )
    }

    private static func normalizedName(_ name: String?) -> String? {
        let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private var completenessScore: Int {
        (bundleIdentifier == nil ? 0 : 1)
            + (displayName == nil ? 0 : 1)
    }
}
