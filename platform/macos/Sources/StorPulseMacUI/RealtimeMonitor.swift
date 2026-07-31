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
    private struct Presentation: Equatable {
        var snapshot: RealtimeSnapshot?
        var samplingState: SamplingState = .starting
        var lastErrorMessage: String?
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
            updatePresentation { $0.lastErrorMessage = error.localizedDescription }
        }
        return nil
    }

    private func execute(_ command: EngineCommand) async {
        do {
            _ = try await engine.execute(command)
            await refreshSnapshot()
        } catch {
            updatePresentation { $0.lastErrorMessage = error.localizedDescription }
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
}
