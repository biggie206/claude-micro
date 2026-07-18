// Session switcher + new-session sheet (US5).
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(state.sessions) { session in
                    Button { connection.send(.setActive(sessionId: session.id)) } label: {
                        HStack {
                            Circle().fill(session.status.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading) {
                                Text(session.projectId).font(.headline)
                                Text(session.lastSnippet.isEmpty ? session.status.label : session.lastSnippet)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if session.active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showNew) {
                List(state.projects) { project in
                    Button(project.name) {
                        connection.send(.createSession(projectId: project.id, depth: nil))
                        showNew = false
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}
