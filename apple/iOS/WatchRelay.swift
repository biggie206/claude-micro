// Phone side of the WatchConnectivity bridge (contracts §WatchConnectivity mapping).
// State → watch via updateApplicationContext (latest-wins, background-safe).
// Commands ← watch via sendMessage, forwarded verbatim to the server socket.
// Haptic-worthy events → sendMessage when reachable, local notification otherwise.
import Foundation
import WatchConnectivity
import UserNotifications

final class WatchRelay: NSObject, WCSessionDelegate {
    /// Set by ServerConnection: forwards watch commands to the server.
    var onCommand: (@MainActor (ClientCommand) -> Void)?
    /// Set by ServerConnection: watch foregrounded and wants a fresh state push.
    var onRefresh: (@MainActor () -> Void)?

    /// Push that arrived before WCSession finished activating. The reconnect snapshot
    /// fires within ms of launch — reliably losing the activation race. Stashes the
    /// ALERT too (watchOS review #2): a gate landing in that window must still buzz.
    private var pendingPush: ([String: Any], AlertEvent?)?

    /// Notification categories (FR-019). Risky requests get NO Approve action —
    /// a lock-screen button is a single tap, and Constitution V requires a distinct
    /// confirmation gesture; tapping the risky notification opens the in-app flow.
    static let permissionCategory = "CLAUDE_MICRO_PERMISSION"
    static let riskyPermissionCategory = "CLAUDE_MICRO_PERMISSION_RISKY"

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.riskyPermissionCategory, actions: [deny], intentIdentifiers: []),
        ])
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @MainActor
    func pushState(_ state: AppState, alert: AlertEvent?) {
        guard WCSession.isSupported() else { return }
        guard WCSession.default.activationState == .activated else {
            pendingPush = (Self.context(for: state), alert)   // flush when activation completes
            return
        }
        // SC-005: callers gate on watch-relevant events (ServerConnection.watchRelevant),
        // so this only runs on real state transitions — latest-wins, background-safe.
        pendingPush = nil
        var context = Self.context(for: state)
        try? WCSession.default.updateApplicationContext(context)

        // T058: application context is deferred/coalesced while the watch app is
        // foregrounded — sendMessage is the real-time channel. FR-023: it gets an error
        // handler; alert-carrying pushes ALSO ride the queued transferUserInfo channel so
        // a reachability flap can never silently eat a haptic (de-duped by alertId).
        context["state"] = true
        if let alert { context.merge(alert.payload) { a, _ in a } }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(context, replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.queueTransfer(context, alert: alert) }
            }
            if alert != nil { queueTransfer(context, alert: alert) }
        } else if alert != nil {
            queueTransfer(context, alert: alert)
        }

        if let alert { notify(alert) }   // phone/lock-screen surface; suppressed while foregrounded
    }

    @MainActor
    private func queueTransfer(_ context: [String: Any], alert: AlertEvent?) {
        WCSession.default.transferUserInfo(context)
    }

    @MainActor
    private static func context(for state: AppState) -> [String: Any] {
        [
            "stale": state.stale,
            "activeSessionId": state.activeSessionId ?? "",
            "depth": state.activeSession?.depth ?? 2,
            "overall": state.overallStatus.rawValue,
            // FR-022: names cross the bridge; payload bounded (snippet ≤80, sessions ≤8)
            // so an oversized context can't silently fail (watchOS review #8).
            "statusProject": Self.statusDrivingProject(state),
            "sessions": state.sessions.prefix(8).map { ["id": $0.id, "projectId": $0.projectId,
                "projectName": state.projectName(forSession: $0.id),
                "status": $0.status.rawValue, "depth": $0.depth, "snippet": String($0.lastSnippet.prefix(80))] },
            "pending": state.pending.map { ["id": $0.id, "sessionId": $0.sessionId,
                "projectName": state.projectName(forSession: $0.sessionId),
                "toolName": $0.toolName, "summary": $0.inputSummary, "risky": $0.risky] },
        ]
    }

    /// The project of the session CAUSING the aggregate status (watchOS review #6) —
    /// a needs-input glance must name the session that needs input, not the active one.
    @MainActor
    private static func statusDrivingProject(_ state: AppState) -> String {
        switch state.overallStatus {
        case .needsInput:
            if let p = state.pending.first { return state.projectName(forSession: p.sessionId) }
        case .error:
            if let s = state.sessions.first(where: { $0.status == .error }) { return state.projectName(forSession: s.id) }
        default: break
        }
        return state.activeSession.map { state.projectName(forSession: $0.id) } ?? ""
    }

    /// FR-022: the notification is built FROM THE TRIGGERING ALERT — title, body, and
    /// approve-target all describe the request that fired, never "current activePending".
    @MainActor
    private func notify(_ alert: AlertEvent) {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = alert.sessionId   // concurrent sessions thread separately
        content.subtitle = alert.projectName
        switch alert.kind {
        case .needsInput:
            content.title = alert.risky ? "\(alert.projectName): risky approval" : "\(alert.projectName) needs input"
            content.body = alert.summary
            content.categoryIdentifier = alert.risky ? Self.riskyPermissionCategory : Self.permissionCategory
            if let requestId = alert.requestId {
                content.userInfo = ["sessionId": alert.sessionId, "requestId": requestId]
            }
        case .complete:
            content.title = "\(alert.projectName): run complete"
            content.body = alert.summary
        case .error:
            content.title = "\(alert.projectName): session error"
            content.body = alert.summary
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["cmd"] as? String == "refresh" {
            Task { @MainActor in self.onRefresh?() }
            return
        }
        guard let cmd = Self.command(from: message) else { return }
        Task { @MainActor in self.onCommand?(cmd) }
    }

    private static func command(from m: [String: Any]) -> ClientCommand? {
        switch m["cmd"] as? String {
        case "approve":
            guard let s = m["sessionId"] as? String, let r = m["requestId"] as? String else { return nil }
            return .approve(sessionId: s, requestId: r, always: m["always"] as? Bool ?? false)
        case "deny":
            guard let s = m["sessionId"] as? String, let r = m["requestId"] as? String else { return nil }
            return .deny(sessionId: s, requestId: r, message: m["message"] as? String)
        case "prompt":
            guard let s = m["sessionId"] as? String, let t = m["text"] as? String else { return nil }
            return .prompt(sessionId: s, text: t, source: "ptt")
        case "set_depth":
            guard let level = m["level"] as? Int else { return nil }
            return .setDepth(sessionId: m["sessionId"] as? String, level: level)
        case "interrupt":
            guard let s = m["sessionId"] as? String else { return nil }
            return .interrupt(sessionId: s)
        case "set_active":
            guard let s = m["sessionId"] as? String else { return nil }
            return .setActive(sessionId: s)
        default:
            return nil
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Flush any push that lost the launch/activation race — context AND alert.
        Task { @MainActor in
            guard activationState == .activated, let (context, alert) = self.pendingPush else { return }
            self.pendingPush = nil
            try? session.updateApplicationContext(context)
            var live = context
            live["state"] = true
            if let alert {
                live.merge(alert.payload) { a, _ in a }
                self.queueTransfer(live, alert: alert)
                self.notify(alert)
            }
            if session.isReachable { session.sendMessage(live, replyHandler: nil) }
        }
    }

    /// Queued commands from the watch (approve/deny/prompt sent while the phone app was
    /// suspended — watchOS review #7). Same handling as live messages.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["cmd"] as? String == "refresh" {
            Task { @MainActor in self.onRefresh?() }
            return
        }
        guard let cmd = Self.command(from: userInfo) else { return }
        Task { @MainActor in self.onCommand?(cmd) }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

// MARK: notification actions (FR-019)

extension WatchRelay: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let sessionId = info["sessionId"] as? String, let requestId = info["requestId"] as? String else {
            return completionHandler()
        }
        let command: ClientCommand?
        switch response.actionIdentifier {
        case "APPROVE": command = .approve(sessionId: sessionId, requestId: requestId, always: false)
        case "DENY":    command = .deny(sessionId: sessionId, requestId: requestId, message: nil)
        default:        command = nil   // default tap just opens the app
        }
        guard let command else { return completionHandler() }
        Task { @MainActor in
            self.onCommand?(command)   // ServerConnection queues + reconnects if the socket is suspended
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])   // foregrounded: the in-app pending card is already visible
    }
}
