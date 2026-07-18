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
            // FR-016: standing grants must be visible and revocable, not invisible server state.
            let granted = state.sessions.filter { !$0.grants.isEmpty }
            if !granted.isEmpty {
                Section("Always-allowed tools") {
                    ForEach(granted) { session in
                        ForEach(session.grants, id: \.self) { tool in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool).font(.subheadline)
                                    Text(session.projectId).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    connection.send(.revokeGrant(sessionId: session.id, toolName: tool))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    Text("Granted for this session only. Risky commands always re-prompt.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Watch Action button: Watch Settings → Action Button → Shortcut → “Claude Primary Action”.")
                    .font(.caption)
            }
        }
    }
}
