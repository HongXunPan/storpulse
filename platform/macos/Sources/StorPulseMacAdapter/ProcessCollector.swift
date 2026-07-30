import Darwin
import Foundation

public struct ProcessCollection: Sendable {
    public let samples: [ProcessIOSample]
    public let discoveredCount: Int
    public let restrictedCount: Int
    public let exitedCount: Int
}

public struct ProcessCollector: Sendable {
    public init() {}

    public func collect() -> ProcessCollection {
        let processIDs = listProcessIDs()
        var samples: [ProcessIOSample] = []
        var restrictedCount = 0
        var exitedCount = 0
        samples.reserveCapacity(processIDs.count)

        for processID in processIDs {
            errno = 0
            guard let sample = readProcess(processID) else {
                if errno == ESRCH {
                    exitedCount += 1
                } else {
                    restrictedCount += 1
                }
                continue
            }
            samples.append(sample)
        }

        return ProcessCollection(
            samples: samples,
            discoveredCount: processIDs.count,
            restrictedCount: restrictedCount,
            exitedCount: exitedCount
        )
    }

    private func listProcessIDs() -> [pid_t] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return [] }

        let stride = MemoryLayout<pid_t>.stride
        let capacity = Int(requiredBytes) / stride + 64
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let filledBytes = processIDs.withUnsafeMutableBytes { bytes in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                bytes.baseAddress,
                Int32(bytes.count)
            )
        }
        guard filledBytes > 0 else { return [] }

        let count = min(Int(filledBytes) / stride, processIDs.count)
        return processIDs.prefix(count).filter { $0 > 0 }
    }

    private func readProcess(_ processID: pid_t) -> ProcessIOSample? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }

        return ProcessIOSample(
            identity: ProcessIdentity(
                pid: processID,
                startTimeTicks: usage.ri_proc_start_abstime
            ),
            parentPID: readParentPID(processID),
            executableName: readProcessName(processID),
            readBytes: usage.ri_diskio_bytesread,
            writeBytes: usage.ri_diskio_byteswritten,
            userTimeNanoseconds: usage.ri_user_time,
            systemTimeNanoseconds: usage.ri_system_time,
            residentBytes: usage.ri_resident_size,
            physicalFootprintBytes: usage.ri_phys_footprint
        )
    }

    private func readParentPID(_ processID: pid_t) -> Int32? {
        var info = proc_bsdinfo()
        let readBytes = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard readBytes == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Int32(info.pbi_ppid)
    }

    private func readProcessName(_ processID: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_name(processID, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return "进程-\(processID)" }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
