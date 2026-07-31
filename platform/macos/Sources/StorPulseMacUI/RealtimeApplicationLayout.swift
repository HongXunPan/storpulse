import SwiftUI

enum RealtimeApplicationLayout {
    static let minimumDetailWidth: CGFloat = 700
    static let horizontalInset: CGFloat = 16
    static let columnSpacing: CGFloat = 10
    static let applicationMinimumWidth: CGFloat = 150
    static let currentRateWidth: CGFloat = 112
    static let recentAverageWidth: CGFloat = 112
    static let runTotalWidth: CGFloat = 108
    static let trailingWidth: CGFloat = 84

    static let minimumRequiredWidth =
        horizontalInset * 2
            + applicationMinimumWidth
            + currentRateWidth
            + recentAverageWidth
            + runTotalWidth
            + trailingWidth
            + columnSpacing * 4
}

struct RealtimeApplicationColumns<
    ApplicationContent: View,
    CurrentRateContent: View,
    RecentAverageContent: View,
    RunTotalContent: View,
    TrailingContent: View
>: View {
    private let application: ApplicationContent
    private let currentRate: CurrentRateContent
    private let recentAverage: RecentAverageContent
    private let runTotal: RunTotalContent
    private let trailing: TrailingContent

    init(
        @ViewBuilder application: () -> ApplicationContent,
        @ViewBuilder currentRate: () -> CurrentRateContent,
        @ViewBuilder recentAverage: () -> RecentAverageContent,
        @ViewBuilder runTotal: () -> RunTotalContent,
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.application = application()
        self.currentRate = currentRate()
        self.recentAverage = recentAverage()
        self.runTotal = runTotal()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: RealtimeApplicationLayout.columnSpacing) {
            application
                .frame(
                    minWidth: RealtimeApplicationLayout.applicationMinimumWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            currentRate
                .frame(
                    width: RealtimeApplicationLayout.currentRateWidth,
                    alignment: .trailing
                )
            recentAverage
                .frame(
                    width: RealtimeApplicationLayout.recentAverageWidth,
                    alignment: .trailing
                )
            runTotal
                .frame(
                    width: RealtimeApplicationLayout.runTotalWidth,
                    alignment: .trailing
                )
            trailing
                .frame(
                    width: RealtimeApplicationLayout.trailingWidth,
                    alignment: .trailing
                )
        }
    }
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
