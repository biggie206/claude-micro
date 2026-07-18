import SwiftUI

@main
struct ClaudeMicroApp: App {
    @StateObject private var state: AppState
    @StateObject private var connection: ServerConnection
    @StateObject private var ptt = PTTController()

    init() {
        let state = AppState()
        let relay = WatchRelay()
        _state = StateObject(wrappedValue: state)
        _connection = StateObject(wrappedValue: ServerConnection(state: state, relay: relay))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ControlPadView()
                    .tabItem { Label("Pad", systemImage: "square.grid.3x3.fill") }
                SessionsView()
                    .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(state)
            .environmentObject(connection)
            .environmentObject(ptt)
            .onAppear {
                ptt.requestAuthorization()
                connection.connect()
            }
            .preferredColorScheme(.dark)
            .tint(.purple)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var connection: ServerConnection
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Companion server (Mac)") {
                TextField("ws://mac-ip:8787/ws", text: $connection.serverURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Token", text: $connection.token)
                Button("Connect") { connection.connect() }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(state.connected ? .green : .red).frame(width: 8, height: 8)
                        Text(state.connected ? "Connected" : "Disconnected")
                    }
                }
                if let err = connection.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            }
            Section {
                Text("Watch Action button: Watch Settings → Action Button → Shortcut → “Claude Primary Action”.")
                    .font(.caption)
            }
        }
    }
}
