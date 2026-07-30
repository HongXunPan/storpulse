import Foundation
import StorPulseFFIBridge
import StorPulseMacAdapter

public protocol StorPulseEngineClient: Sendable {
    func ingest(_ snapshot: RawSnapshot) async throws
    func snapshot(at monotonicNanoseconds: UInt64) async throws -> RealtimeSnapshot
    func execute(_ command: EngineCommand) async throws -> EngineCommandResponse
}

public enum EngineClientError: LocalizedError, Equatable {
    case libraryUnavailable(String)
    case engineRejected(status: Int32, message: String)
    case emptyResponse
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .libraryUnavailable(message):
            "共享引擎不可用：\(message)"
        case let .engineRejected(status, message):
            "共享引擎拒绝请求（\(status)）：\(message)"
        case .emptyResponse:
            "共享引擎返回了空响应"
        case let .invalidResponse(message):
            "共享引擎响应无法解析：\(message)"
        }
    }
}

public actor RustEngineClient: StorPulseEngineClient {
    private let bridgeAddress: UInt
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(libraryURL: URL? = nil) throws {
        let resolvedURL = libraryURL ?? Self.defaultLibraryURL()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let handle = resolvedURL.path.withCString { path in
            sp_bridge_open(path, &errorPointer)
        }
        guard let handle else {
            let message = errorPointer.map { String(cString: $0) } ?? "无法打开动态库"
            sp_bridge_string_free(errorPointer)
            throw EngineClientError.libraryUnavailable(message)
        }
        bridgeAddress = UInt(bitPattern: handle)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
    }

    deinit {
        sp_bridge_close(OpaquePointer(bitPattern: bridgeAddress))
    }

    public func ingest(_ snapshot: RawSnapshot) async throws {
        let data = try encoder.encode(snapshot)
        let status = data.withUnsafeBytes { bytes in
            sp_bridge_ingest(
                bridge,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard status == 0 else {
            throw EngineClientError.engineRejected(
                status: status,
                message: readLastError()
            )
        }
    }

    public func snapshot(at monotonicNanoseconds: UInt64) async throws -> RealtimeSnapshot {
        try decode(
            RealtimeSnapshot.self,
            from: sp_bridge_snapshot(bridge, monotonicNanoseconds)
        )
    }

    public func execute(_ command: EngineCommand) async throws -> EngineCommandResponse {
        let data = try encoder.encode(command)
        let buffer = data.withUnsafeBytes { bytes in
            sp_bridge_command(
                bridge,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        return try decode(EngineCommandResponse.self, from: buffer)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from buffer: SpBridgeBuffer
    ) throws -> Value {
        defer { sp_bridge_buffer_free(buffer) }
        guard buffer.status == 0 else {
            throw EngineClientError.engineRejected(
                status: buffer.status,
                message: readLastError()
            )
        }
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            throw EngineClientError.emptyResponse
        }
        do {
            return try decoder.decode(type, from: Data(bytes: pointer, count: buffer.len))
        } catch {
            throw EngineClientError.invalidResponse(error.localizedDescription)
        }
    }

    private func readLastError() -> String {
        let buffer = sp_bridge_last_error(bridge)
        defer { sp_bridge_buffer_free(buffer) }
        guard let pointer = buffer.ptr, buffer.len > 0 else { return "未知错误" }
        let data = Data(bytes: pointer, count: buffer.len)
        let message = try? JSONDecoder().decode(EngineErrorMessage.self, from: data)
        return message?.message ?? "未知错误"
    }

    private nonisolated var bridge: OpaquePointer? {
        OpaquePointer(bitPattern: bridgeAddress)
    }

    public static func defaultLibraryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL {
        if let configured = environment["STORPULSE_ENGINE_LIBRARY"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        let relativePaths = [
            ".codex-tmp/cargo-target/debug/libstorpulse_ffi.dylib",
            ".codex-tmp/cargo-target/debug/deps/libstorpulse_ffi.dylib",
        ]
        var directory = currentDirectoryURL.standardizedFileURL
        for _ in 0 ..< 6 {
            for relativePath in relativePaths {
                let candidate = directory.appending(path: relativePath)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            directory.deleteLastPathComponent()
        }
        return currentDirectoryURL.appending(path: relativePaths[0])
    }
}

public actor UnavailableEngineClient: StorPulseEngineClient {
    private let error: EngineClientError

    public init(message: String) {
        error = .libraryUnavailable(message)
    }

    public func ingest(_: RawSnapshot) async throws {
        throw error
    }

    public func snapshot(at _: UInt64) async throws -> RealtimeSnapshot {
        throw error
    }

    public func execute(_: EngineCommand) async throws -> EngineCommandResponse {
        throw error
    }
}

private struct EngineErrorMessage: Decodable {
    let message: String
}
