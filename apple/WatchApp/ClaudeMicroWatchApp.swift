import AppIntents
import SwiftUI

@main
struct ClaudeMicroWatchApp: App {
    @StateObject private var link = PhoneLink.shared

    init() {
        // T060: static App Shortcut discovery doesn't fire for sideloaded watch apps —
        // register explicitly so "Claude Primary Action" appears in the Action Button
        // Shortcut picker (FR-007).
        ClaudeMicroShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            WatchControlView()
        }
    }
}
