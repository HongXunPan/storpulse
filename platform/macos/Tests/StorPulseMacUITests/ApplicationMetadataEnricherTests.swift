@testable import StorPulseMacUI
import Foundation
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

@Test("XPC 服务优先使用 Bundle 自身的本地化服务名")
func xpcServicePrefersLocalizedBundleDisplayName() {
    let displayName = ApplicationMetadata.resolvedDisplayName(
        localizedName: "Docker的",
        bundleURL: URL(fileURLWithPath: "/System/Library/Example.xpc"),
        localizedBundleDisplayName: "虚拟机服务"
    )

    #expect(displayName == "虚拟机服务")
}

@Test("普通应用继续使用系统提供的本地化应用名")
func regularApplicationKeepsRunningApplicationName() {
    let displayName = ApplicationMetadata.resolvedDisplayName(
        localizedName: "Docker",
        bundleURL: URL(fileURLWithPath: "/Applications/Docker.app"),
        localizedBundleDisplayName: "不应采用的备用名称"
    )

    #expect(displayName == "Docker")
}
