import Foundation

public enum MetricScope: String, Codable, Sendable {
    case device
    case storageProcess = "storage_process"
}

public enum Freshness: String, Codable, Sendable {
    case fresh
    case stale
    case paused
    case failed
}

public enum Completeness: String, Codable, Sendable {
    case complete
    case partial
    case restricted
    case unsupported
}

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTimeTicks: UInt64

    public init(pid: Int32, startTimeTicks: UInt64) {
        self.pid = pid
        self.startTimeTicks = startTimeTicks
    }
}

public struct ProcessIOSample: Codable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32?
    public let executableName: String
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let userTimeNanoseconds: UInt64
    public let systemTimeNanoseconds: UInt64
    public let residentBytes: UInt64
    public let physicalFootprintBytes: UInt64

    public init(
        identity: ProcessIdentity,
        parentPID: Int32?,
        executableName: String,
        readBytes: UInt64,
        writeBytes: UInt64,
        userTimeNanoseconds: UInt64,
        systemTimeNanoseconds: UInt64,
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.executableName = executableName
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.userTimeNanoseconds = userTimeNanoseconds
        self.systemTimeNanoseconds = systemTimeNanoseconds
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct DeviceIOSample: Codable, Sendable {
    public let registryEntryID: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let readOperations: UInt64?
    public let writeOperations: UInt64?

    public init(
        registryEntryID: UInt64,
        readBytes: UInt64,
        writeBytes: UInt64,
        readOperations: UInt64?,
        writeOperations: UInt64?
    ) {
        self.registryEntryID = registryEntryID
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readOperations = readOperations
        self.writeOperations = writeOperations
    }
}

public struct CollectionSummary: Codable, Sendable {
    public let discoveredProcesses: Int
    public let readableProcesses: Int
    public let restrictedProcesses: Int
    public let exitedProcesses: Int
    public let deviceCount: Int
    public let collectionDurationNanoseconds: UInt64

    public init(
        discoveredProcesses: Int,
        readableProcesses: Int,
        restrictedProcesses: Int,
        exitedProcesses: Int,
        deviceCount: Int,
        collectionDurationNanoseconds: UInt64
    ) {
        self.discoveredProcesses = discoveredProcesses
        self.readableProcesses = readableProcesses
        self.restrictedProcesses = restrictedProcesses
        self.exitedProcesses = exitedProcesses
        self.deviceCount = deviceCount
        self.collectionDurationNanoseconds = collectionDurationNanoseconds
    }
}

public struct RawSnapshot: Codable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let capturedAt: Date
    public let monotonicNanoseconds: UInt64
    public let metricSource: String
    public let metricScope: [MetricScope]
    public let freshness: Freshness
    public let completeness: Completeness
    public let processes: [ProcessIOSample]
    public let devices: [DeviceIOSample]
    public let summary: CollectionSummary

    public init(
        capturedAt: Date,
        monotonicNanoseconds: UInt64,
        freshness: Freshness,
        completeness: Completeness,
        processes: [ProcessIOSample],
        devices: [DeviceIOSample],
        summary: CollectionSummary
    ) {
        schemaVersion = Self.schemaVersion
        self.capturedAt = capturedAt
        self.monotonicNanoseconds = monotonicNanoseconds
        metricSource = "macos.libproc-rusage-v4+iokit-block-storage"
        metricScope = [.device, .storageProcess]
        self.freshness = freshness
        self.completeness = completeness
        self.processes = processes
        self.devices = devices
        self.summary = summary
    }
}
