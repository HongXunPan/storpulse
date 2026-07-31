import Foundation
import UserNotifications

public protocol ReminderDelivering: Sendable {
    func requestAuthorization() async throws -> Bool
    func deliver(activity: ActivitySummary) async throws
}

public enum ReminderServiceError: LocalizedError, Equatable {
    case applicationBundleUnavailable

    public var errorDescription: String? {
        switch self {
        case .applicationBundleUnavailable:
            "当前启动方式缺少 macOS 应用 Bundle，无法使用系统通知"
        }
    }
}

public actor SystemReminderService: ReminderDelivering {
    private var center: UNUserNotificationCenter?
    private let applicationBundleIdentifier: String?

    public init(
        center: UNUserNotificationCenter? = nil,
        applicationBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.center = center
        self.applicationBundleIdentifier = applicationBundleIdentifier
    }

    public func requestAuthorization() async throws -> Bool {
        try await resolvedCenter().requestAuthorization(options: [.alert, .sound])
    }

    public func deliver(activity: ActivitySummary) async throws {
        let center = try resolvedCenter()
        let content = UNMutableNotificationContent()
        content.title = "检测到持续磁盘 I/O"
        content.body = "\(activity.displayName) 已持续 \(IOPresentation.duration(milliseconds: activity.durationMilliseconds))"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "storpulse-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    private func resolvedCenter() throws -> UNUserNotificationCenter {
        if let center {
            return center
        }
        guard applicationBundleIdentifier?.isEmpty == false else {
            throw ReminderServiceError.applicationBundleUnavailable
        }
        let center = UNUserNotificationCenter.current()
        self.center = center
        return center
    }
}
