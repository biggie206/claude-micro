// Main watch surface: Digital Crown = thinking depth (5 detents, haptic per detent),
// pending-permission approve/reject, dictation PTT via TextFieldLink (no SFSpeech on watchOS).
import SwiftUI
import WatchKit

struct WatchControlView: View {
    @ObservedObject var link = PhoneLink.shared
    @State private var crownDepth: Double = 2
    @State private var depthDebounce: Task<Void, Never>?
    /// Set by PrimaryActionIntent when the Action button is pressed with nothing pending.
    /// SwiftUI can't launch dictation programmatically, so we pulse the Speak button instead.
    @State private var highlightSpeak = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                statusHeader

                if let p = link.oldestPending {
                    pendingView(p)
                } else {
                    idleControls
                }

                depthRow
            }
            .focusable(true)
            .digitalCrownRotation(
                $crownDepth, from: 0, through: 4, by: 1,
                sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true
            )
            .onChange(of: crownDepth) { _, newValue in
                let level = Int(newValue.rounded())
                guard level != link.depth else { return }
                depthDebounce?.cancel()
                depthDebounce = Task {
                    try? await Task.sleep(for: .milliseconds(300))   // debounce per research.md R4
                    guard !Task.isCancelled else { return }
                    link.setDepth(level)
                }
            }
            .onChange(of: link.depth) { _, newValue in crownDepth = Double(newValue) }
            .onAppear { crownDepth = Double(link.depth) }
            .onReceive(NotificationCenter.default.publisher(for: .openDictation)) { _ in
                withAnimation(.easeInOut(duration: 0.4).repeatCount(4)) { highlightSpeak = true }
                Task { try? await Task.sleep(for: .seconds(2)); highlightSpeak = false }
            }
            .navigationTitle("Claude")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { sessionPicker } label: { Image(systemName: "rectangle.stack") }
                }
            }
        }
    }

    private var statusHeader: some View {
        let status = SessionStatus(rawValue: link.overall) ?? .idle
        return HStack(spacing: 6) {
            Circle().fill(link.stale ? .gray : status.color).frame(width: 10, height: 10)
            Text(link.stale ? "PHONE?" : status.label.uppercased())
                .font(.system(size: 12, weight: .bold)).tracking(1)
            Spacer()
        }
    }

    private func pendingView(_ p: PhoneLink.WatchPending) -> some View {
        VStack(spacing: 6) {
            Text(p.toolName).font(.headline).foregroundStyle(p.risky ? .red : .orange)
            Text(p.summary).font(.system(size: 12, design: .monospaced)).lineLimit(2)
            HStack {
                Button { link.approve(p) } label: { Image(systemName: "checkmark").bold() }
                    .tint(.green)
                Button { link.deny(p) } label: { Image(systemName: "xmark").bold() }
                    .tint(.red)
            }
            if p.risky { Text("⚠ risky — Action button won't auto-approve").font(.system(size: 10)) }
        }
    }

    private var idleControls: some View {
        VStack(spacing: 6) {
            TextFieldLink(prompt: Text("Prompt Claude")) {
                Label("Speak", systemImage: "mic.fill").frame(maxWidth: .infinity)
            } onSubmit: { text in
                link.prompt(text)
            }
            .tint(highlightSpeak ? .pink : .purple)

            Button { link.interrupt() } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.orange)
        }
    }

    private var depthRow: some View {
        HStack {
            Image(systemName: "brain")
            Gauge(value: Double(link.depth), in: 0...4) { EmptyView() }
                .gaugeStyle(.accessoryLinear).tint(.purple)
            Text(DepthLevel(rawValue: link.depth)?.label ?? "?")
                .font(.system(size: 11, weight: .semibold))
        }
        .font(.system(size: 11))
    }

    private var sessionPicker: some View {
        List(link.sessions) { s in
            Button {
                link.setActive(s.id)
            } label: {
                HStack {
                    Circle().fill((SessionStatus(rawValue: s.status) ?? .idle).color).frame(width: 8, height: 8)
                    Text(s.projectId).font(.system(size: 13))
                    Spacer()
                    if s.id == link.activeSessionId { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle("Sessions")
    }
}
