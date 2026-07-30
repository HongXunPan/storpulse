import Foundation

struct MinuteBucketAccumulator {
    private struct Totals {
        let readBytes: UInt64
        let writeBytes: UInt64
    }

    private struct Key: Hashable {
        let bucketStartedAt: Date
        let applicationID: String?
    }

    private struct MutableBucket {
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        var peak = IORate(readBytesPerSecond: 0, writeBytesPerSecond: 0)
        var metricSource: String
        var completeness: String
    }

    private var previousDeviceTotals: Totals?
    private var previousApplicationTotals: [String: Totals] = [:]
    private var buckets: [Key: MutableBucket] = [:]

    mutating func ingest(_ snapshot: RealtimeSnapshot) {
        guard let capturedAt = Self.parseDate(snapshot.capturedAt) else { return }
        let minute = Date(timeIntervalSince1970: floor(capturedAt.timeIntervalSince1970 / 60) * 60)

        let deviceTotals = Totals(
            readBytes: snapshot.devices.reduce(0) { $0.saturatingAdd($1.runReadBytes) },
            writeBytes: snapshot.devices.reduce(0) { $0.saturatingAdd($1.runWriteBytes) }
        )
        if let previousDeviceTotals {
            add(
                key: Key(bucketStartedAt: minute, applicationID: nil),
                readBytes: deviceTotals.readBytes.saturatingSubtract(previousDeviceTotals.readBytes),
                writeBytes: deviceTotals.writeBytes.saturatingSubtract(previousDeviceTotals.writeBytes),
                rate: snapshot.deviceRate,
                source: snapshot.metricSource,
                completeness: snapshot.completeness
            )
        }
        previousDeviceTotals = deviceTotals

        for application in snapshot.applications {
            let totals = Totals(
                readBytes: application.runReadBytes,
                writeBytes: application.runWriteBytes
            )
            if let previous = previousApplicationTotals[application.applicationID] {
                add(
                    key: Key(bucketStartedAt: minute, applicationID: application.applicationID),
                    readBytes: totals.readBytes.saturatingSubtract(previous.readBytes),
                    writeBytes: totals.writeBytes.saturatingSubtract(previous.writeBytes),
                    rate: application.current,
                    source: snapshot.metricSource,
                    completeness: snapshot.completeness
                )
            }
            previousApplicationTotals[application.applicationID] = totals
        }
    }

    mutating func drainFinished(before date: Date) -> [MinuteBucketRecord] {
        let currentMinute = floor(date.timeIntervalSince1970 / 60) * 60
        return drain { $0.bucketStartedAt.timeIntervalSince1970 < currentMinute }
    }

    mutating func drainAll() -> [MinuteBucketRecord] {
        drain { _ in true }
    }

    private mutating func add(
        key: Key,
        readBytes: UInt64,
        writeBytes: UInt64,
        rate: IORate?,
        source: String,
        completeness: String
    ) {
        var bucket = buckets[key] ?? MutableBucket(
            metricSource: source,
            completeness: completeness
        )
        bucket.readBytes = bucket.readBytes.saturatingAdd(readBytes)
        bucket.writeBytes = bucket.writeBytes.saturatingAdd(writeBytes)
        if let rate {
            bucket.peak = IORate(
                readBytesPerSecond: max(
                    bucket.peak.readBytesPerSecond,
                    rate.readBytesPerSecond
                ),
                writeBytesPerSecond: max(
                    bucket.peak.writeBytesPerSecond,
                    rate.writeBytesPerSecond
                )
            )
        }
        bucket.completeness = Self.lessComplete(bucket.completeness, completeness)
        buckets[key] = bucket
    }

    private mutating func drain(
        where predicate: (Key) -> Bool
    ) -> [MinuteBucketRecord] {
        let keys = buckets.keys.filter(predicate)
        let records = keys.compactMap { key -> MinuteBucketRecord? in
            guard let bucket = buckets.removeValue(forKey: key) else { return nil }
            return MinuteBucketRecord(
                bucketStartedAt: Self.formatDate(key.bucketStartedAt),
                applicationID: key.applicationID,
                readBytes: bucket.readBytes,
                writeBytes: bucket.writeBytes,
                peak: bucket.peak,
                metricSource: bucket.metricSource,
                completeness: bucket.completeness
            )
        }
        return records.sorted {
            ($0.bucketStartedAt, $0.applicationID ?? "")
                < ($1.bucketStartedAt, $1.applicationID ?? "")
        }
    }

    private static func lessComplete(_ lhs: String, _ rhs: String) -> String {
        let ranking = ["complete": 0, "partial": 1, "restricted": 2, "unsupported": 3]
        return (ranking[lhs, default: 4] >= ranking[rhs, default: 4]) ? lhs : rhs
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
