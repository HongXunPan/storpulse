@testable import StorPulseMacUI
import Testing

@Test("缺少应用 Bundle 时通知服务返回错误而不崩溃")
func notificationServiceRequiresApplicationBundle() async {
    let service = SystemReminderService(applicationBundleIdentifier: nil)

    await #expect(throws: ReminderServiceError.applicationBundleUnavailable) {
        _ = try await service.requestAuthorization()
    }
}
