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
    func pushState(_ state: AppState, haptic: HapticSignal?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let context: [String: Any] = [
            "stale": state.stale,
            "activeSessionId": state.activeSessionId ?? "",
            "depth": state.activeSession?.depth ?? 2,
            "overall": state.overallStatus.rawValue,
            "sessions": state.sessions.map { ["id": $0.id, "projectId": $0.projectId, "status": $0.status.rawValue, "depth": $0.depth, "snippet": $0.lastSnippet] },
            "pending": state.pending.map { ["id": $0.id, "sessionId": $0.sessionId, "toolName": $0.toolName, "summary": $0.inputSummary, "risky": $0.risky] },
        ]

        // SC-005: callers gate on watch-relevant events (ServerConnection.watchRelevant),
        // so this only runs on real state transitions — latest-wins, background-safe.
        try? WCSession.default.updateApplicationContext(context)

        if let haptic {
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(["haptic": String(describing: haptic)], replyHandler: nil)
            } else {
                notify(for: haptic, state: state)   // background watch → notification mirrors to wrist
            }
        }
    }

    @MainActor
    private func notify(for haptic: HapticSignal, state: AppState) {
        let content = UNMutableNotificationContent()
        switch haptic {
        case .needsInput:
            if let pending = state.activePending {
                content.title = pending.risky ? "Claude needs input — risky" : "Claude needs input"
                content.body = pending.inputSummary
                content.categoryIdentifier = pending.risky ? Self.riskyPermissionCategory : Self.permissionCategory
                content.userInfo = ["sessionId": pending.sessionId, "requestId": pending.id]
            } else {
                content.title = "Claude needs input"
                content.body = "A session is waiting on a permission."
            }
        case .complete:
            content.title = "Run complete"
        case .error:
            content.title = "Session error"
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
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

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
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
