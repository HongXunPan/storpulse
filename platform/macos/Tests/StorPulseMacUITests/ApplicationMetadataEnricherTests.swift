@testable import StorPulseMacUI
import Testing

@Test("应用元数据索引忽略无效 PID 并容忍重复键")
func applicationMetadataIndexHandlesDuplicateProcessIdentifiers() {
    let sparse = ApplicationMetadata(
        bundleIdentifier: nil,
        displayName: "编辑器"
    )
    let complete = ApplicationMetadata(
        bundleIdentifier: "com.example.editor",
        displayName: "编辑器"
    )
    let index = ApplicationMetadataEnricher.metadataIndex([
        (processIdentifier: -1, metadata: sparse),
        (processIdentifier: -1, metadata: complete),
        (processIdentifier: 42, metadata: sparse),
        (processIdentifier: 42, metadata: complete),
    ])

    #expect(index.count == 1)
    #expect(index[-1] == nil)
    #expect(index[42] == complete)
}
