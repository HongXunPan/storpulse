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
    func observationSessionEnded(_ session: ObservationSession) async
}

@MainActor
public final class RealtimeMonitor: ObservableObject {
    @Published public private(set) var snapshot: RealtimeSnapshot?
    @Published public private(set) var samplingState: SamplingState = .starting
    @Published public private(set) var lastErrorMessage: String?

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

    public var ratesAreTrustworthy: Bool {
        samplingState == .live && snapshot?.freshness == "fresh"
    }

    public func start() {
        guard samplingTask == nil else { return }
        samplingState = .starting
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
        samplingState = .paused
    }

    public func sampleOnce() async {
        let rawSnapshot = await source.collect()
        do {
            try await engine.ingest(rawSnapshot)
            let realtime = try await engine.snapshot(
                at: DispatchTime.now().uptimeNanoseconds
            )
            snapshot = realtime
            consecutiveFailures = 0
            lastErrorMessage = nil
            samplingState = realtime.freshness == "fresh" ? .live : .stale
            for observer in observers {
                await observer.realtimeSnapshotProduced(realtime)
            }
        } catch {
            consecutiveFailures += 1
            lastErrorMessage = error.localizedDescription
            if consecutiveFailures >= 3 {
                samplingState = .stale
            } else {
                samplingState = .interrupted(missedSamples: consecutiveFailures)
            }
        }
    }

    public func startObservation() async {
        let now = Date()
        let command = EngineCommand.startObservation(
            sessionID: UUID().uuidString.lowercased(),
            startedAt: Self.iso8601(now),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        await execute(command)
    }

    @discardableResult
    public func stopObservation() async -> ObservationSession? {
        let command = EngineCommand.stopObservation(
            endedAt: Self.iso8601(Date()),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        do {
            let response = try await engine.execute(command)
            if case let .observationStopped(session) = response {
                for observer in observers {
                    await observer.observationSessionEnded(session)
                }
                await refreshSnapshot()
                return session
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        return nil
    }

    private func execute(_ command: EngineCommand) async {
        do {
            _ = try await engine.execute(command)
            await refreshSnapshot()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshSnapshot() async {
        do {
            snapshot = try await engine.snapshot(at: DispatchTime.now().uptimeNanoseconds)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
