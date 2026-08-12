import SwiftUI

@main
struct PinStickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .frame(width: 460, height: 520)
        }
    }
}
