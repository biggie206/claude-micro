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

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        try? WCSession.default.updateApplicationContext(context)

        if let haptic {
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(["haptic": String(describing: haptic)], replyHandler: nil)
            } else {
                notify(for: haptic, state: state)   // background watch → notification mirrors to wrist
            }
        }
    }

    private func notify(for haptic: HapticSignal, state: AppState) {
        let content = UNMutableNotificationContent()
        switch haptic {
        case .needsInput:
            content.title = "Claude needs input"
            Task { @MainActor in content.body = state.activePending?.inputSummary ?? "A session is waiting on a permission." }
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
