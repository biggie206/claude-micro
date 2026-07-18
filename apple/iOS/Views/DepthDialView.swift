// On-screen rotary dial: the Codex Micro thinking-depth encoder, in software.
import SwiftUI

struct DepthDialView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    /// Depth at gesture start — steps are computed against this anchor, not live state,
    /// so one continuous drag walks the detents deterministically. @GestureState (not
    /// @State) so an interrupted/cancelled gesture can never leave a stale anchor behind.
    @GestureState private var anchorDepth: Int?

    private var level: DepthLevel { DepthLevel(rawValue: state.activeSession?.depth ?? 2) ?? .standard }

    var body: some View {
        HStack(spacing: 16) {
            dial
            VStack(alignment: .leading, spacing: 2) {
                Text("THINKING DEPTH").font(.caption2.bold()).tracking(1.2).foregroundStyle(.secondary)
                Text(level.label).font(.headline)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: level)
                Text("applies to next turn").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking depth: \(level.label)")
        .accessibilityAdjustableAction { direction in
            let next = max(0, min(4, level.rawValue + (direction == .increment ? 1 : -1)))
            setDepth(next, send: true)
        }
    }

    private var dial: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 8).frame(width: 74, height: 74)
            // detent tick marks
            ForEach(0..<5) { i in
                Capsule()
                    .fill(i <= level.rawValue ? Color.purple : .white.opacity(0.25))
                    .frame(width: 3, height: 8)
                    .offset(y: -45)
                    .rotationEffect(.degrees(Double(i) * 72 - 144))
            }
            Circle()
                .trim(from: 0, to: CGFloat(level.rawValue + 1) / 5)
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 74, height: 74)
                .animation(.snappy(duration: 0.25), value: level)
            Text("\(level.rawValue)").font(.title2.bold())
                .contentTransition(.numericText())
                .animation(.snappy, value: level)
        }
        .frame(width: 98, height: 98)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($anchorDepth) { _, anchor, _ in
                    if anchor == nil { anchor = state.activeSession?.depth ?? 2 }
                }
                .onChanged { g in
                    guard let anchor = anchorDepth else { return }
                    let target = max(0, min(4, anchor + Int(-g.translation.height / 34)))
                    setDepth(target, send: false)   // optimistic; server reconciles
                }
                .onEnded { _ in
                    connection.send(.setDepth(sessionId: state.activeSession?.id, level: state.activeSession?.depth ?? 2))
                })
    }

    private func setDepth(_ target: Int, send: Bool) {
        if target != state.activeSession?.depth,
           let i = state.sessions.firstIndex(where: { $0.id == state.activeSession?.id }) {
            state.sessions[i].depth = target
            Haptics.selection.selectionChanged()   // one click per detent, like the hardware dial
        }
        if send { connection.send(.setDepth(sessionId: state.activeSession?.id, level: target)) }
    }
}
