import Foundation
import IOKit

public struct DeviceCollector: Sendable {
    public init() {}

    public func collect() -> [DeviceIOSample] {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            return []
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var samples: [DeviceIOSample] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let sample = readDevice(service) else { continue }
            samples.append(sample)
        }
        return samples.sorted { $0.deviceID < $1.deviceID }
    }

    private func readDevice(_ service: io_registry_entry_t) -> DeviceIOSample? {
        var registryEntryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS else {
            return nil
        }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "Statistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
            let statistics = property as? [String: Any],
            let readBytes = number(statistics["Bytes (Read)"]),
            let writeBytes = number(statistics["Bytes (Write)"])
        else {
            return nil
        }

        return DeviceIOSample(
            deviceID: makeDeviceID(registryEntryID: registryEntryID),
            readBytes: readBytes,
            writeBytes: writeBytes,
            readOperations: number(statistics["Operations (Read)"]),
            writeOperations: number(statistics["Operations (Write)"])
        )
    }

    private func number(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private func makeDeviceID(registryEntryID: UInt64) -> String {
        "macos:ioreg:\(registryEntryID)"
    }
}
