// Session switcher + new-session sheet (US5).
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Group {
                if state.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Sessions", systemImage: "rectangle.stack.badge.plus")
                    } description: {
                        Text(state.connected ? "Start a Claude session in one of your Mac projects."
                                             : "Connect to your Mac in Settings first.")
                    } actions: {
                        if state.connected {
                            Button("New Session") { showNew = true }.buttonStyle(.borderedProminent).tint(.purple)
                        }
                    }
                } else {
                    List {
                        ForEach(state.sessions) { session in
                            Button { connection.send(.setActive(sessionId: session.id)) } label: {
                                SessionRow(session: session)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .disabled(!state.connected || state.projects.isEmpty)
                    .accessibilityLabel("New session")
            }
            .sheet(isPresented: $showNew) {
                NavigationStack {
                    List(state.projects) { project in
                        Button {
                            connection.send(.createSession(projectId: project.id, depth: nil))
                            showNew = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.headline)
                                Text(project.cwd).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .navigationTitle("New session in…")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(session.status.color).frame(width: 10, height: 10)
                .shadow(color: session.status.color.opacity(0.8), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectId).font(.headline)
                    Text(session.status.label).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(session.status.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(session.status.color)
                }
                Text(session.lastSnippet.isEmpty ? "No output yet" : session.lastSnippet)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    if let ago = relativeActivity { Text(ago) }
                    Text(session.costUSD, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if session.active {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                    .accessibilityLabel("Active session")
            }
        }
        .padding(.vertical, 2)
    }

    private var relativeActivity: String? {
        guard let date = ISO8601DateFormatter.cached.date(from: session.lastActivityAt) else { return nil }
        return RelativeDateTimeFormatter.cached.localizedString(for: date, relativeTo: .now)
    }
}

extension ISO8601DateFormatter {
    static let cached: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension RelativeDateTimeFormatter {
    static let cached: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
