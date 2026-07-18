import SwiftUI

@main
struct ClaudeMicroWatchApp: App {
    @StateObject private var link = PhoneLink.shared

    var body: some Scene {
        WindowGroup {
            WatchControlView()
        }
    }
}
