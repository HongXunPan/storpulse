import SwiftUI

enum RealtimeApplicationLayout {
    static let minimumDetailWidth: CGFloat = 700
    static let horizontalInset: CGFloat = 16
    static let applicationColumnMinimumWidth: CGFloat = 170
    static let applicationColumnIdealWidth: CGFloat = 230
    static let applicationColumnMaximumWidth: CGFloat = 360
    static let currentRateWidth: CGFloat = 118
    static let recentAverageWidth: CGFloat = 118
    static let runTotalWidth: CGFloat = 112
    static let durationWidth: CGFloat = 88
    static let inspectorMinimumWidth: CGFloat = 320
    static let inspectorIdealWidth: CGFloat = 360
    static let inspectorMaximumWidth: CGFloat = 460

    static let minimumRequiredWidth =
        applicationColumnMinimumWidth
            + currentRateWidth
            + recentAverageWidth
            + runTotalWidth
            + durationWidth
}

struct RealtimeRatePairView: View {
    let title: String
    let rate: IORate?
    let textStyle: Font.TextStyle

    init(
        title: String,
        rate: IORate?,
        textStyle: Font.TextStyle = .caption
    ) {
        self.title = title
        self.rate = rate
        self.textStyle = textStyle
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("读 \(IOPresentation.rate(rate?.readBytesPerSecond))")
            Text("写 \(IOPresentation.rate(rate?.writeBytesPerSecond))")
        }
        .font(.system(textStyle, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityLabel(
            "\(title)读取 \(IOPresentation.rate(rate?.readBytesPerSecond))，写入 \(IOPresentation.rate(rate?.writeBytesPerSecond))"
        )
    }
}

struct RealtimeTotalPairView: View {
    let readBytes: UInt64
    let writeBytes: UInt64
    let textStyle: Font.TextStyle

    init(
        readBytes: UInt64,
        writeBytes: UInt64,
        textStyle: Font.TextStyle = .caption
    ) {
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.textStyle = textStyle
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("读 \(IOPresentation.bytes(readBytes))")
            Text("写 \(IOPresentation.bytes(writeBytes))")
        }
        .font(.system(textStyle, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityLabel(
            "本次累计读取 \(IOPresentation.bytes(readBytes))，写入 \(IOPresentation.bytes(writeBytes))"
        )
    }
}
