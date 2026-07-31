import Combine
import Dispatch
import Foundation

public enum SamplingState: Equatable, Sendable {
    case starting
    case live
    case interrupted(missedSamples: Int)
    case stale
    case failed(String)
    case paused

    public var title: String {
        switch self {
        case .starting: "正在预热"
        case .live: "实时"
        case let .interrupted(missedSamples): "采样中断 \(missedSamples)/3"
        case .stale: "数据已过期"
        case .failed: "采样失败"
        case .paused: "已暂停"
        }
    }
}

public protocol RealtimeSnapshotObserver: Sendable {
    func realtimeSnapshotProduced(_ snapshot: RealtimeSnapshot) async
    func observationRecordEnded(_ record: ObservationRecord) async
    func observationRecordRenamed(sessionID: String, name: String) async
}

@MainActor
public final class RealtimeMonitor: ObservableObject {
    private struct Presentation: Equatable {
        var snapshot: RealtimeSnapshot?
        var samplingState: SamplingState = .starting
        var lastErrorMessage: String?
        var activeObservationName: String?
        var completedObservationRecord: ObservationRecord?
        var observationRecords: [ObservationRecord] = []
    }

    @Published private var presentation = Presentation()

    private let engine: any StorPulseEngineClient
    private let source: any SnapshotSource
    private let observers: [any RealtimeSnapshotObserver]
    private let sampleIntervalNanoseconds: UInt64
    private var consecutiveFailures = 0
    private var samplingTask: Task<Void, Never>?

    public init(
        engine: any StorPulseEngineClient,
        source: any SnapshotSource = MacOSSnapshotSource(),
        observers: [any RealtimeSnapshotObserver] = [],
        sampleIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.engine = engine
        self.source = source
        self.observers = observers
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
    }

    deinit {
        samplingTask?.cancel()
    }

    public var snapshot: RealtimeSnapshot? {
        presentation.snapshot
    }

    public var samplingState: SamplingState {
        presentation.samplingState
    }

    public var lastErrorMessage: String? {
        presentation.lastErrorMessage
    }

    public var activeObservationName: String? {
        presentation.activeObservationName
    }

    public var completedObservationRecord: ObservationRecord? {
        presentation.completedObservationRecord
    }

    public var observationRecords: [ObservationRecord] {
        presentation.observationRecords
    }

    public var ratesAreTrustworthy: Bool {
        samplingState == .live && snapshot?.freshness == "fresh"
    }

    public func start() {
        guard samplingTask == nil else { return }
        updatePresentation { $0.samplingState = .starting }
        samplingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await sampleOnce()
                do {
                    try await Task.sleep(nanoseconds: sampleIntervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        updatePresentation { $0.samplingState = .paused }
    }

    public func sampleOnce() async {
        let rawSnapshot = await source.collect()
        do {
            try await engine.ingest(rawSnapshot)
            let realtime = try await engine.snapshot(
                at: DispatchTime.now().uptimeNanoseconds
            )
            consecutiveFailures = 0
            updatePresentation {
                $0.snapshot = realtime
                $0.lastErrorMessage = nil
                $0.samplingState = realtime.freshness == "fresh" ? .live : .stale
            }
            for observer in observers {
                await observer.realtimeSnapshotProduced(realtime)
            }
        } catch {
            consecutiveFailures += 1
            updatePresentation {
                $0.lastErrorMessage = error.localizedDescription
                if consecutiveFailures >= 3 {
                    $0.samplingState = .stale
                } else {
                    $0.samplingState = .interrupted(
                        missedSamples: consecutiveFailures
                    )
                }
            }
        }
    }

    public func startObservation() async {
        let now = Date()
        let name = ObservationRecord.defaultName(at: now)
        let command = EngineCommand.startObservation(
            sessionID: UUID().uuidString.lowercased(),
            startedAt: Self.iso8601(now),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        do {
            _ = try await engine.execute(command)
            updatePresentation {
                $0.activeObservationName = name
                $0.lastErrorMessage = nil
            }
            await refreshSnapshot()
        } catch {
            updatePresentation { $0.lastErrorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    public func stopObservation() async -> ObservationRecord? {
        let command = EngineCommand.stopObservation(
            endedAt: Self.iso8601(Date()),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        do {
            let response = try await engine.execute(command)
            if case let .observationStopped(session) = response {
                let record = ObservationRecord(
                    name: presentation.activeObservationName ?? "",
                    session: session
                )
                updatePresentation {
                    $0.activeObservationName = nil
                    $0.completedObservationRecord = record
                    $0.observationRecords = Self.inserting(
                        record,
                        into: $0.observationRecords
                    )
                }
                for observer in observers {
                    await observer.observationRecordEnded(record)
                }
                await refreshSnapshot()
                return record
            }
        } catch {
            updatePresentation { $0.lastErrorMessage = error.localizedDescription }
        }
        return nil
    }

    public func renameObservationRecord(
        sessionID: String,
        name: String
    ) async -> Bool {
        guard let current = presentation.observationRecords.first(where: {
            $0.id == sessionID
        }) else {
            return false
        }
        let renamed = current.renamed(to: name)
        guard renamed != current else { return true }
        updatePresentation {
            $0.observationRecords = $0.observationRecords.map {
                $0.id == sessionID ? renamed : $0
            }
            if $0.completedObservationRecord?.id == sessionID {
                $0.completedObservationRecord = renamed
            }
        }
        for observer in observers {
            await observer.observationRecordRenamed(
                sessionID: sessionID,
                name: renamed.name
            )
        }
        return true
    }

    public func dismissCompletedObservationRecord() {
        updatePresentation {
            $0.completedObservationRecord = nil
        }
    }

    private func refreshSnapshot() async {
        do {
            let snapshot = try await engine.snapshot(
                at: DispatchTime.now().uptimeNanoseconds
            )
            updatePresentation { $0.snapshot = snapshot }
        } catch {
            updatePresentation { $0.lastErrorMessage = error.localizedDescription }
        }
    }

    private func updatePresentation(_ update: (inout Presentation) -> Void) {
        var next = presentation
        update(&next)
        guard next != presentation else { return }
        presentation = next
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func inserting(
        _ record: ObservationRecord,
        into records: [ObservationRecord]
    ) -> [ObservationRecord] {
        Array(
            ([record] + records.filter { $0.id != record.id })
                .prefix(100)
        )
    }
}
