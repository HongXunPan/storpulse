import SwiftUI
import StorPulseMacUI

@main
struct StorPulseMacApp: App {
    @NSApplicationDelegateAdaptor(StorPulseApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开实时观察") {
                    applicationDelegate.showRealtimeObservation()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(replacing: .appSettings) {
                Button("历史与提醒…") {
                    applicationDelegate.showHistoryAndReminders()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
