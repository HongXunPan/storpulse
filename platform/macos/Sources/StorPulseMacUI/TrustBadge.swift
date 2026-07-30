import SwiftUI

struct TrustBadge: View {
    let state: SamplingState
    let completeness: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("数据状态：\(label)")
    }

    private var label: String {
        guard state == .live else { return state.title }
        switch completeness {
        case "complete": return "实时 · 完整"
        case "restricted": return "实时 · 部分进程受限"
        case "partial": return "实时 · 覆盖不完整"
        case "unsupported": return "当前环境不支持"
        default: return "实时"
        }
    }

    private var color: Color {
        if state == .live && completeness == "complete" { return .green }
        if state == .live { return .orange }
        switch state {
        case .starting: return .secondary
        case .interrupted, .stale: return .orange
        case .failed: return .red
        case .paused: return .secondary
        case .live: return .green
        }
    }
}
