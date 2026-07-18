import SwiftUI

@main
struct ClaudeMicroApp: App {
    @StateObject private var state: AppState
    @StateObject private var connection: ServerConnection

    init() {
        let state = AppState()
        let relay = WatchRelay()
        _state = StateObject(wrappedValue: state)
        _connection = StateObject(wrappedValue: ServerConnection(state: state, relay: relay))
    }

    var body: some Scene {
        WindowGroup {
            BridgeHomeView()
                .environmentObject(state)
                .environmentObject(connection)
                .onAppear { connection.connect() }
                .preferredColorScheme(.dark)
                .tint(.purple)
        }
    }
}
