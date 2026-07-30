import Foundation
import UserNotifications

public protocol ReminderDelivering: Sendable {
    func requestAuthorization() async throws -> Bool
    func deliver(activity: ActivitySummary) async throws
}

public actor SystemReminderService: ReminderDelivering {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func deliver(activity: ActivitySummary) async throws {
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
}
