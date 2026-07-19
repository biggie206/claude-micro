// The whole iPhone app (FR-005, bridge direction): connection + pairing, the
// pending-gate safety card notifications tap into, and grant management.
// Rich control lives on the watch; rich chat lives in the official Claude app.
import SwiftUI
import WatchConnectivity

struct BridgeHomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if let request = state.activePending {
                    PermissionSection(request: request)
                }
                serverSection
                watchLinkSection
                grantsSection
                Section {
                    Text("Control lives on your watch: crown = thinking depth, Action button = approve / dictate. Set it under Watch Settings → Action Button → Shortcut → “Claude Primary Action”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Claude Micro")
        }
        .sheet(isPresented: $showScanner) {
            PairingSheet { url, token in
                connection.serverURL = url
                connection.token = token
                showScanner = false
                connection.connect()   // persists URL + Keychain token
            }
        }
    }

    private var statusSection: some View {
        let status = state.activeSession?.status ?? .idle
        return Section {
            HStack(spacing: 10) {
                Circle().fill(state.stale ? .gray : status.color).frame(width: 12, height: 12)
                    .shadow(color: status.color.opacity(state.stale ? 0 : 0.8), radius: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.stale ? "Stale — reconnecting" : status.label)
                        .font(.headline)
                    if let s = state.activeSession {
                        Text("\(s.projectId) · \(s.costUSD, format: .currency(code: "USD").precision(.fractionLength(2)))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text(state.connected ? "No active session" : "Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.3), value: status)
            .accessibilityElement(children: .combine)
            if let err = connection.lastError {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
                    .onTapGesture { connection.lastError = nil }
                    .accessibilityHint("Double tap to dismiss")
            }
        }
    }

    private var serverSection: some View {
        Section("Companion server (Mac)") {
            Button { showScanner = true } label: {
                Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
            }
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
        }
    }

    /// Live WCSession truth — the three flags that decide whether the watch gets anything.
    private var watchLinkSection: some View {
        Section("Watch link") {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let s = WCSession.isSupported() ? WCSession.default : nil
                VStack(alignment: .leading, spacing: 6) {
                    linkRow("Paired", s?.isPaired ?? false)
                    linkRow("Watch app installed", s?.isWatchAppInstalled ?? false)
                    linkRow("Reachable now", s?.isReachable ?? false)
                    Text("Activation: \((s?.activationState == .activated) ? "activated" : "not activated")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func linkRow(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Circle().fill(ok ? .green : .red).frame(width: 8, height: 8)
            Text(ok ? "Yes" : "No").foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var grantsSection: some View {
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
    }
}

/// The safety surface a risky notification tap lands on (FR-019 / Constitution V).
struct PermissionSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ServerConnection
    let request: PendingPermission
    @State private var riskyToConfirm: PendingPermission?

    var body: some View {
        Section("Pending approval") {
            // FR-022: name the originating session so the user knows which chat this is.
            Text(state.projectName(forSession: request.sessionId))
                .font(.caption.bold()).textCase(.uppercase).foregroundStyle(.secondary)
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
            }
            if state.pending.count > 1 {
                Text("+\(state.pending.count - 1) more queued").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(request.riskTint.opacity(0.12))
        .onChange(of: state.pending) { _, pending in
            if let r = riskyToConfirm, !pending.contains(where: { $0.id == r.id }) { riskyToConfirm = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.risky ? "Risky p" : "P")ermission request: \(request.toolName). \(request.inputSummary)")
    }
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
