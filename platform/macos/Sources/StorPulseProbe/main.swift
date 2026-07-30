import Foundation
import StorPulseMacAdapter

@main
struct StorPulseProbeCommand {
    static func main() throws {
        let snapshot = MacOSCollector().collect()
        let data = try SnapshotEncoder.encode(snapshot, prettyPrinted: true)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))

        if snapshot.freshness == .failed {
            throw ProbeError.collectionFailed
        }
    }
}

enum ProbeError: Error {
    case collectionFailed
}
