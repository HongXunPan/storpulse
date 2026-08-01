import Foundation
import Testing
@testable import StorPulseMacAdapter

private struct Stage0Environment: Encodable {
    let operatingSystem: String
    let architecture: String
    let standardUser: Bool
}

private struct Stage0Measurements: Encodable {
    let discoveredProcesses: Int
    let readableProcesses: Int
    let restrictedProcesses: Int
    let deviceCount: Int
    let idleWriteDeltaBytes: UInt64
    let idleCPUPercent: Double
    let workloadReadDeltaBytes: UInt64
    let workloadWriteDeltaBytes: UInt64
    let deviceReadDeltaBytes: UInt64
    let deviceWriteDeltaBytes: UInt64
    let physicalFootprintBytes: UInt64
    let maximumCollectionMilliseconds: Double
    let shortLivedProcessesSpawned: Int
    let shortLivedProcessesStillVisible: Int
    let iostatExitCode: Int32
    let iostatIntervalMegabytes: Double?
}

private struct Stage0EvidenceReport: Encodable {
    let schemaVersion = 1
    let generatedAt: Date
    let evidenceLevel: String
    let metricSource: String
    let environment: Stage0Environment
    let measurements: Stage0Measurements
    let limitations: [String]
}

@Test("阶段 0 受控负载生成脱敏证据")
func controlledWorkloadProducesEvidence() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let reportPath = environment["STORPULSE_STAGE0_REPORT"],
          let workDirectory = environment["STORPULSE_STAGE0_WORKDIR"]
    else {
        return
    }

    let fileManager = FileManager.default
    let workURL = URL(fileURLWithPath: workDirectory, isDirectory: true)
    try? fileManager.removeItem(at: workURL)
    try fileManager.createDirectory(at: workURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workURL) }

    let collector = MacOSCollector()
    let idleStart = collector.collect()
    Thread.sleep(forTimeInterval: 2)
    let idleEnd = collector.collect()
    let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let idleStartProcess = try #require(process(currentPID, in: idleStart))
    let idleEndProcess = try #require(process(currentPID, in: idleEnd))
    #expect(idleStartProcess.identity == idleEndProcess.identity)

    let iostat = try startIOStat()
    Thread.sleep(forTimeInterval: 0.25)
    try performControlledWorkload(in: workURL)
    let shortLivedCount = try spawnShortLivedProcesses(count: 40)
    iostat.process.waitUntilExit()

    let workloadEnd = collector.collect()
    let workloadProcess = try #require(process(currentPID, in: workloadEnd))
    #expect(idleEndProcess.identity == workloadProcess.identity)

    let idleElapsed = max(
        idleEnd.monotonicNanoseconds - idleStart.monotonicNanoseconds,
        1
    )
    let idleCPU = delta(idleStartProcess.userTimeNanoseconds, idleEndProcess.userTimeNanoseconds)
        + delta(idleStartProcess.systemTimeNanoseconds, idleEndProcess.systemTimeNanoseconds)
    let iostatOutput = String(
        decoding: iostat.output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )

    let measurements = Stage0Measurements(
        discoveredProcesses: workloadEnd.summary.discoveredProcesses,
        readableProcesses: workloadEnd.summary.readableProcesses,
        restrictedProcesses: workloadEnd.summary.restrictedProcesses,
        deviceCount: workloadEnd.summary.deviceCount,
        idleWriteDeltaBytes: delta(idleStartProcess.writeBytes, idleEndProcess.writeBytes),
        idleCPUPercent: Double(idleCPU) / Double(idleElapsed) * 100,
        workloadReadDeltaBytes: delta(idleEndProcess.readBytes, workloadProcess.readBytes),
        workloadWriteDeltaBytes: delta(idleEndProcess.writeBytes, workloadProcess.writeBytes),
        deviceReadDeltaBytes: deviceDelta(from: idleEnd, to: workloadEnd, keyPath: \.readBytes),
        deviceWriteDeltaBytes: deviceDelta(from: idleEnd, to: workloadEnd, keyPath: \.writeBytes),
        physicalFootprintBytes: workloadProcess.physicalFootprintBytes,
        maximumCollectionMilliseconds: maximumCollectionDuration([idleStart, idleEnd, workloadEnd]),
        shortLivedProcessesSpawned: shortLivedCount,
        shortLivedProcessesStillVisible: workloadEnd.processes.filter {
            $0.executableName == "true"
        }.count,
        iostatExitCode: iostat.process.terminationStatus,
        iostatIntervalMegabytes: parseIOStatIntervalMegabytes(iostatOutput)
    )

    let report = Stage0EvidenceReport(
        generatedAt: Date(),
        evidenceLevel: "macOS 26.5 Intel 开发者预览",
        metricSource: workloadEnd.metricSource,
        environment: Stage0Environment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architectureName,
            standardUser: getuid() != 0
        ),
        measurements: measurements,
        limitations: [
            "未验证 Apple Silicon 与旧版 macOS",
            "未验证 App Sandbox、签名与发行",
            "短命进程可能在采样窗口内消失",
            "设备统计与进程统计不用于计算未归因差额",
        ]
    )
    try writeReport(report, to: reportPath)

    #expect(measurements.readableProcesses > 0)
    #expect(measurements.deviceCount > 0)
    #expect(measurements.idleWriteDeltaBytes == 0)
    #expect(measurements.workloadWriteDeltaBytes > 0)
    #expect(measurements.deviceWriteDeltaBytes > 0)
    #expect(measurements.iostatExitCode == 0)
    #expect((measurements.iostatIntervalMegabytes ?? 0) > 0)
    #expect(measurements.maximumCollectionMilliseconds < 1_000)
}

@Test("iostat 解析接受前导空格")
func iostatParserAcceptsLeadingWhitespace() {
    let output = """
                  disk0
        KB/t xfrs   MB
       95.61 100 9.34
      110.94 299 32.39
    """
    #expect(parseIOStatIntervalMegabytes(output) == 32.39)
}

private var architectureName: String {
    #if arch(x86_64)
    "x86_64"
    #elseif arch(arm64)
    "arm64"
    #else
    "unknown"
    #endif
}

private func process(_ pid: Int32, in snapshot: RawSnapshot) -> ProcessIOSample? {
    snapshot.processes.first { $0.identity.pid == pid }
}

private func delta(_ before: UInt64, _ after: UInt64) -> UInt64 {
    after >= before ? after - before : 0
}

private func deviceDelta(
    from before: RawSnapshot,
    to after: RawSnapshot,
    keyPath: KeyPath<DeviceIOSample, UInt64>
) -> UInt64 {
    let beforeByID = Dictionary(uniqueKeysWithValues: before.devices.map {
        ($0.deviceID, $0[keyPath: keyPath])
    })
    return after.devices.reduce(into: 0) { total, device in
        guard let previous = beforeByID[device.deviceID] else { return }
        total += delta(previous, device[keyPath: keyPath])
    }
}

private func maximumCollectionDuration(_ snapshots: [RawSnapshot]) -> Double {
    let maximum = snapshots.map(\.summary.collectionDurationNanoseconds).max() ?? 0
    return Double(maximum) / 1_000_000
}

private func performControlledWorkload(in directory: URL) throws {
    let largeFile = directory.appendingPathComponent("sequential.bin")
    _ = FileManager.default.createFile(atPath: largeFile.path, contents: nil)
    let writer = try FileHandle(forWritingTo: largeFile)
    for index in 0..<64 {
        var block = Data(repeating: 0xA5, count: 1_048_576)
        block[0] = UInt8(index)
        try writer.write(contentsOf: block)
    }
    try writer.synchronize()
    try writer.close()

    let reader = try FileHandle(forReadingFrom: largeFile)
    while try reader.read(upToCount: 1_048_576)?.isEmpty == false {}
    try reader.close()

    let smallDirectory = directory.appendingPathComponent("small-files", isDirectory: true)
    try FileManager.default.createDirectory(at: smallDirectory, withIntermediateDirectories: true)
    let payload = Data(repeating: 0x5A, count: 4_096)
    for index in 0..<500 {
        try payload.write(to: smallDirectory.appendingPathComponent("item-\(index)"))
    }
}

private func spawnShortLivedProcesses(count: Int) throws -> Int {
    for _ in 0..<count {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
    }
    return count
}

private func startIOStat() throws -> (process: Process, output: Pipe) {
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/iostat")
    process.arguments = ["-Id", "-c", "2", "-w", "1"]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    return (process, output)
}

private func parseIOStatIntervalMegabytes(_ output: String) -> Double? {
    let numericRows = output.split(separator: "\n").compactMap { line -> [Substring]? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3, Double(fields[0]) != nil else { return nil }
        return fields
    }
    guard let last = numericRows.last else { return nil }
    return Double(last.last ?? "")
}

private func writeReport(_ report: Stage0EvidenceReport, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
