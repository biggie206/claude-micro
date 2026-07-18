// The Micro-style control pad: status banner (RGB analog), pending-permission card,
// key grid (accept / reject / interrupt / new / skills), hold-to-talk, depth dial.
import SwiftUI

struct ControlPadView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    @EnvironmentObject var ptt: PTTController

    var body: some View {
        VStack(spacing: 14) {
            statusBanner
            if let request = state.activePending {
                PermissionCard(request: request)
            } else {
                transcriptPeek
            }
            skillPad
            keyGrid
            DepthDialView()
            pttKey
        }
        .padding()
    }

    private var statusBanner: some View {
        let status = state.activeSession?.status ?? .idle
        return HStack {
            Circle().fill(status.color).frame(width: 12, height: 12)
                .shadow(color: status.color, radius: state.stale ? 0 : 6)
            Text(state.stale ? "STALE — reconnecting" : status.label.uppercased())
                .font(.caption.bold()).tracking(1.5)
            Spacer()
            if let s = state.activeSession {
                Text("\(s.projectId) · $\(s.costUSD, specifier: "%.2f")").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(status.color.opacity(state.stale ? 0.08 : 0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private var transcriptPeek: some View {
        ScrollView {
            Text(state.transcript[state.activeSession?.id ?? ""] ?? "—")
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 110)
        .padding(8)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var keyGrid: some View {
        HStack(spacing: 10) {
            MicroKey(icon: "checkmark", label: "Accept", color: .green) {
                if let r = state.activePending { connection.send(.approve(sessionId: r.sessionId, requestId: r.id, always: false)) }
            }
            MicroKey(icon: "xmark", label: "Reject", color: .red) {
                if let r = state.activePending { connection.send(.deny(sessionId: r.sessionId, requestId: r.id, message: nil)) }
            }
            MicroKey(icon: "stop.fill", label: "Stop", color: .orange) {
                if let s = state.activeSession { connection.send(.interrupt(sessionId: s.id)) }
            }
            MicroKey(icon: "plus", label: "New", color: .blue) {
                if let p = state.projects.first { connection.send(.createSession(projectId: p.id, depth: nil)) }
            }
        }
    }

    /// 4-way joystick analog: swipe pad bound to server-configured skills.
    private var skillPad: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.white.opacity(0.06))
            .frame(height: 64)
            .overlay(Text("⟵ explain   ⟰ review   ⟱ commit   test ⟶").font(.caption2).foregroundStyle(.secondary))
            .gesture(
                DragGesture(minimumDistance: 24).onEnded { g in
                    let dx = g.translation.width, dy = g.translation.height
                    let direction = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
                    connection.send(.skill(sessionId: state.activeSession?.id, direction: direction))
                })
    }

    private var pttKey: some View {
        Text(ptt.isRecording ? (ptt.partial.isEmpty ? "Listening…" : ptt.partial) : "HOLD TO TALK")
            .font(ptt.isRecording ? .caption : .headline.bold())
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(ptt.isRecording ? Color.red : Color.purple, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 60) {
                // press began (perform fires after minimumDuration while still holding)
                ptt.start()
            } onPressingChanged: { pressing in
                if !pressing, ptt.isRecording {
                    let text = ptt.stop()
                    if !text.isEmpty, let s = state.activeSession {
                        connection.send(.prompt(sessionId: s.id, text: text, source: "ptt"))
                    }
                }
            }
    }
}

struct MicroKey: View {
    let icon: String, label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3.bold())
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

struct PermissionCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    let request: PendingPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.toolName, systemImage: request.risky ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(request.risky ? .red : .orange)
            Text(request.inputSummary).font(.system(.caption, design: .monospaced))
            HStack {
                Button("Allow") { connection.send(.approve(sessionId: request.sessionId, requestId: request.id, always: false)) }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button("Always") { connection.send(.approve(sessionId: request.sessionId, requestId: request.id, always: true)) }
                    .buttonStyle(.bordered).disabled(request.risky)   // Constitution V
                Button("Deny") { connection.send(.deny(sessionId: request.sessionId, requestId: request.id, message: nil)) }
                    .buttonStyle(.bordered).tint(.red)
                if state.pending.count > 1 { Spacer(); Text("+\(state.pending.count - 1) queued").font(.caption2) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .frame(height: 118)
    }
}
