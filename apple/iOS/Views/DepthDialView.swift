// On-screen rotary dial: the Codex Micro thinking-depth encoder, in software.
import SwiftUI

struct DepthDialView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    @State private var dragAccumulator: CGFloat = 0

    private var level: DepthLevel { DepthLevel(rawValue: state.activeSession?.depth ?? 2) ?? .standard }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 8).frame(width: 74, height: 74)
                Circle()
                    .trim(from: 0, to: CGFloat(level.rawValue + 1) / 5)
                    .stroke(Color.purple, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 74, height: 74)
                Text("\(level.rawValue)").font(.title2.bold())
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        dragAccumulator += g.translation.height - dragAccumulator
                        let step = Int(-g.translation.height / 34)
                        let target = max(0, min(4, (state.activeSession?.depth ?? 2) + step))
                        if target != state.activeSession?.depth, let i = state.sessions.firstIndex(where: { $0.id == state.activeSession?.id }) {
                            state.sessions[i].depth = target   // optimistic; server reconciles
                        }
                    }
                    .onEnded { _ in
                        dragAccumulator = 0
                        connection.send(.setDepth(sessionId: state.activeSession?.id, level: state.activeSession?.depth ?? 2))
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    })

            VStack(alignment: .leading, spacing: 2) {
                Text("THINKING DEPTH").font(.caption2.bold()).tracking(1.2).foregroundStyle(.secondary)
                Text(level.label).font(.headline)
                Text("applies to next turn").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
