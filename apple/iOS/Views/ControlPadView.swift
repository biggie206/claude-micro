// The Micro-style control pad: status banner (RGB analog), pending-permission card,
// key grid (accept / reject / interrupt / new / skills), hold-to-talk, depth dial.
import SwiftUI

struct ControlPadView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    @EnvironmentObject var ptt: PTTController
    @State private var riskyToConfirm: PendingPermission?
    @State private var skillFlash: String?

    var body: some View {
        VStack(spacing: 14) {
            statusBanner
            if let err = connection.lastError {
                errorLine(err)
            }
            if state.sessions.isEmpty {
                emptyState
            } else {
                if let request = state.activePending {
                    PermissionCard(request: request)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    transcriptPeek
                }
                skillPad
                keyGrid
                DepthDialView()
                pttKey
            }
        }
        .padding()
        .animation(.snappy(duration: 0.25), value: state.activePending)
        .animation(.snappy(duration: 0.25), value: state.sessions.isEmpty)
        // If the pinned request resolves elsewhere while the dialog is open (or armed),
        // drop it — otherwise the stale value re-presents against the next pending item.
        .onChange(of: state.pending) { _, pending in
            if let r = riskyToConfirm, !pending.contains(where: { $0.id == r.id }) { riskyToConfirm = nil }
        }
    }

    // MARK: status banner (RGB lighting analog)

    private var statusBanner: some View {
        let status = state.activeSession?.status ?? .idle
        let busy = status == .thinking || status == .working
        return HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 12, height: 12)
                .shadow(color: status.color.opacity(0.9), radius: state.stale ? 0 : 6)
                .modifier(PulseWhile(active: busy && !state.stale))
            Text(state.stale ? "STALE — RECONNECTING" : status.label.uppercased())
                .font(.caption.bold()).tracking(1.5)
                .contentTransition(.opacity)
            Spacer()
            if let s = state.activeSession {
                Text("\(s.projectId) · \(s.costUSD, format: .currency(code: "USD").precision(.fractionLength(2)))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(status.color.opacity(state.stale ? 0.08 : 0.18), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(status.color.opacity(state.stale ? 0.1 : 0.35), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: status)
        .animation(.easeInOut(duration: 0.3), value: state.stale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.stale ? "Connection stale, reconnecting" : "Session status: \(status.label)")
    }

    private func errorLine(_ err: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(err).lineLimit(1)
            Spacer()
            Image(systemName: "xmark").font(.caption2)
        }
        .font(.caption2)
        .foregroundStyle(.red)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.red.opacity(0.12), in: Capsule())
        .onTapGesture { connection.lastError = nil }
        .transition(.opacity)
        .accessibilityLabel("Server error: \(err). Double tap to dismiss.")
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 44)).foregroundStyle(.purple)
            Text("No sessions").font(.title3.bold())
            Text(state.connected
                 ? "Start a Claude session in one of your Mac projects."
                 : "Connect to your Mac in Settings, then start a session.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if state.connected, let p = state.projects.first {
                Button {
                    connection.send(.createSession(projectId: p.id, depth: nil))
                    Haptics.medium.impactOccurred()
                } label: {
                    Label("New session in \(p.name)", systemImage: "plus")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: transcript

    private var transcriptPeek: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(activeTranscript.isEmpty ? "Waiting for output…" : activeTranscript)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(activeTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("transcript-end")
            }
            .onChange(of: activeTranscript) {
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("transcript-end", anchor: .bottom) }
            }
        }
        .frame(height: 110)
        .padding(10)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Assistant output")
    }

    private var activeTranscript: String {
        state.transcript[state.activeSession?.id ?? ""] ?? ""
    }

    // MARK: key grid

    private var keyGrid: some View {
        HStack(spacing: 10) {
            // Constitution V: the grid key must not bypass the risky confirmation the card enforces.
            MicroKey(icon: "checkmark", label: "Accept", color: .green, enabled: state.activePending != nil) {
                guard let r = state.activePending else { return }
                if r.risky { riskyToConfirm = r }
                else { connection.send(.approve(sessionId: r.sessionId, requestId: r.id, always: false)) }
            }
            MicroKey(icon: "xmark", label: "Reject", color: .red, enabled: state.activePending != nil) {
                if let r = state.activePending { connection.send(.deny(sessionId: r.sessionId, requestId: r.id, message: nil)) }
            }
            MicroKey(icon: "stop.fill", label: "Stop", color: .orange,
                     enabled: state.activeSession.map { [.thinking, .working, .needsInput].contains($0.status) } ?? false) {
                if let s = state.activeSession { connection.send(.interrupt(sessionId: s.id)) }
            }
            MicroKey(icon: "plus", label: "New", color: .blue, enabled: state.connected && !state.projects.isEmpty) {
                if let p = state.projects.first { connection.send(.createSession(projectId: p.id, depth: nil)) }
            }
        }
        .riskyApprovalDialog($riskyToConfirm) { req in
            connection.send(.approve(sessionId: req.sessionId, requestId: req.id, always: false))
        }
    }

    // MARK: skill pad (joystick analog)

    /// 4-way joystick analog: swipe pad bound to server-configured skills.
    private var skillPad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
            VStack(spacing: 2) {
                Image(systemName: skillFlash == "up" ? "chevron.up.circle.fill" : "chevron.up")
                HStack(spacing: 26) {
                    Image(systemName: skillFlash == "left" ? "chevron.left.circle.fill" : "chevron.left")
                    Text("SKILLS").font(.caption2.bold()).tracking(2).foregroundStyle(.secondary)
                    Image(systemName: skillFlash == "right" ? "chevron.right.circle.fill" : "chevron.right")
                }
                Image(systemName: skillFlash == "down" ? "chevron.down.circle.fill" : "chevron.down")
            }
            .font(.caption)
            .foregroundStyle(.purple)
        }
        .frame(height: 64)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { g in
                let dx = g.translation.width, dy = g.translation.height
                let direction = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
                connection.send(.skill(sessionId: state.activeSession?.id, direction: direction))
                Haptics.rigid.impactOccurred()
                withAnimation(.snappy) { skillFlash = direction }
                Task { try? await Task.sleep(for: .milliseconds(450)); withAnimation { skillFlash = nil } }
            })
        .accessibilityLabel("Skill pad. Swipe up: review. Down: commit. Left: explain. Right: test.")
    }

    // MARK: push-to-talk

    private var pttKey: some View {
        Text(ptt.isRecording ? (ptt.partial.isEmpty ? "Listening…" : ptt.partial) : "HOLD TO TALK")
            .font(ptt.isRecording ? .caption : .headline.bold())
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(ptt.isRecording ? Color.red : Color.purple, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .shadow(color: .red.opacity(ptt.isRecording ? 0.55 : 0), radius: 14)
            .scaleEffect(ptt.isRecording ? 1.02 : 1)
            .animation(.easeInOut(duration: 0.25), value: ptt.isRecording)
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 60) {
                // press began (perform fires after minimumDuration while still holding)
                Haptics.heavy.impactOccurred()
                ptt.start()
            } onPressingChanged: { pressing in
                if !pressing, ptt.isRecording {
                    let text = ptt.stop()
                    if !text.isEmpty, let s = state.activeSession {
                        connection.send(.prompt(sessionId: s.id, text: text, source: "ptt"))
                        Haptics.notice.notificationOccurred(.success)
                    }
                }
            }
            .accessibilityLabel(ptt.isRecording ? "Recording voice prompt" : "Hold to talk")
            .accessibilityHint("Hold, speak your prompt, then release to send")
    }
}

/// Subtle opacity pulse while `active` — the "thinking" shimmer of the Micro's RGB keys.
private struct PulseWhile: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: dim)
            .onChange(of: active) { _, isActive in dim = isActive }
            .onAppear { dim = active }
    }
}

struct MicroKey: View {
    let icon: String, label: String
    let color: Color
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light.impactOccurred()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3.bold())
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(color.opacity(enabled ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(enabled ? color : color.opacity(0.35))
        }
        .buttonStyle(MicroKeyStyle())
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.2), value: enabled)
        .accessibilityLabel(label)
    }
}

/// Hardware-key feel: scale + brighten on press.
struct MicroKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct PermissionCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    let request: PendingPermission
    @State private var riskyToConfirm: PendingPermission?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.toolName, systemImage: request.risky ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(request.riskTint)
            Text(request.inputSummary).font(.system(.caption, design: .monospaced))
            HStack {
                Button("Allow") {
                    if request.risky { riskyToConfirm = request }
                    else { connection.send(.approve(sessionId: request.sessionId, requestId: request.id, always: false)) }
                }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .riskyApprovalDialog($riskyToConfirm) { req in
                        connection.send(.approve(sessionId: req.sessionId, requestId: req.id, always: false))
                    }
                Button("Always") { connection.send(.approve(sessionId: request.sessionId, requestId: request.id, always: true)) }
                    .buttonStyle(.bordered).disabled(request.risky)   // Constitution V
                Button("Deny") { connection.send(.deny(sessionId: request.sessionId, requestId: request.id, message: nil)) }
                    .buttonStyle(.bordered).tint(.red)
                if state.pending.count > 1 { Spacer(); Text("+\(state.pending.count - 1) queued").font(.caption2) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(request.riskTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(request.riskTint.opacity(0.4), lineWidth: 1))
        .frame(height: 118)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.risky ? "Risky p" : "P")ermission request: \(request.toolName). \(request.inputSummary)")
        .onChange(of: state.pending) { _, pending in
            if let r = riskyToConfirm, !pending.contains(where: { $0.id == r.id }) { riskyToConfirm = nil }
        }
    }
}

/// Shared, pre-warmed feedback generators — per-tap construction loses the prepare()
/// latency benefit and allocates on every gesture.
enum Haptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let medium = UIImpactFeedbackGenerator(style: .medium)
    static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    static let selection = UISelectionFeedbackGenerator()
    static let notice = UINotificationFeedbackGenerator()
}

extension View {
    /// Constitution V chokepoint: every risky approval on iOS confirms through this one
    /// dialog, pinned via `presenting:` to the request captured at tap time so it can
    /// never rebind to a different pending request while open.
    func riskyApprovalDialog(_ item: Binding<PendingPermission?>,
                             onConfirm: @escaping (PendingPermission) -> Void) -> some View {
        confirmationDialog("Run risky tool?",
                           isPresented: Binding(get: { item.wrappedValue != nil },
                                                set: { if !$0 { item.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: item.wrappedValue) { req in
            Button("Run \(req.toolName)", role: .destructive) { onConfirm(req) }
            Button("Cancel", role: .cancel) {}
        } message: { req in
            Text(req.inputSummary)
        }
    }
}
