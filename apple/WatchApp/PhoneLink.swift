// Watch side of the WatchConnectivity bridge. TN3135: the watch never opens sockets;
// state arrives via sendMessage (live) / transferUserInfo (queued) / applicationContext
// (background latest-wins); commands go out with the same fast-path + queue pairing.
import Foundation
import UserNotifications
import WatchConnectivity
import WatchKit
import WidgetKit

@MainActor
final class PhoneLink: NSObject, ObservableObject {
    static let shared = PhoneLink()

    @Published var sessions: [WatchSession] = []
    @Published var pending: [WatchPending] = []
    @Published var depth: Int = 2
    @Published var activeSessionId: String = ""
    @Published var overall: String = "idle"
    @Published var statusProject: String = ""
    @Published var stale = true

    /// FR-023: one haptic per alert regardless of how many channels deliver it.
    private var playedAlertIds: [String] = []

    struct WatchSession: Identifiable, Equatable {
        let id: String, projectId: String, projectName: String, status: String, depth: Int, snippet: String
    }
    struct WatchPending: Identifiable, Equatable {
        let id: String, sessionId: String, projectName: String, toolName: String, summary: String, risky: Bool
    }

    var oldestPending: WatchPending? {
        pending.first { $0.sessionId == activeSessionId } ?? pending.first
    }

    /// Action-button scope (spec Edge Cases): oldest pending for the *active* session only.
    var actionButtonPending: WatchPending? {
        pending.first { $0.sessionId == activeSessionId }
    }

    override private init() {
        super.init()
        // FR-023: watch-side local notifications need watch-side permission (the phone's
        // grant does not carry over) — without this, time-sensitive wrist alerts can't fire.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: commands (watch → phone → server)

    func approve(_ p: WatchPending) {
        send(["cmd": "approve", "sessionId": p.sessionId, "requestId": p.id])
        WKInterfaceDevice.current().play(.success)
    }
    func deny(_ p: WatchPending) {
        send(["cmd": "deny", "sessionId": p.sessionId, "requestId": p.id])
        WKInterfaceDevice.current().play(.retry)
    }
    func prompt(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !activeSessionId.isEmpty else { return }
        send(["cmd": "prompt", "sessionId": activeSessionId, "text": text])
        WKInterfaceDevice.current().play(.start)
    }
    func setDepth(_ level: Int) {
        depth = level   // optimistic; context update reconciles
        send(["cmd": "set_depth", "level": level])
    }
    func interrupt() {
        guard !activeSessionId.isEmpty else { return }
        send(["cmd": "interrupt", "sessionId": activeSessionId])
        WKInterfaceDevice.current().play(.stop)
    }
    func setActive(_ id: String) { send(["cmd": "set_active", "sessionId": id]) }

    /// Foreground refresh: re-ingest the stored context (delivered while backgrounded —
    /// no delegate callback fires for it on foregrounding) and ask the phone for a live push.
    func refresh() {
        let stored = WCSession.default.receivedApplicationContext
        if !stored.isEmpty { ingest(stored) }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["cmd": "refresh"], replyHandler: nil)
        }
    }

    /// watchOS review #7: an approve issued while the phone app is suspended must not
    /// vanish. Fast path via sendMessage with error fallback to the transferUserInfo
    /// queue; unreachable goes straight to the queue (a click acknowledges "queued").
    private func send(_ payload: [String: Any]) {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(payload)
            }
        } else {
            WCSession.default.transferUserInfo(payload)
            WKInterfaceDevice.current().play(.click)   // queued, not lost
        }
    }

    // MARK: state ingest

    private var lastReloadAt = Date.distantPast
    private var lastOverall = ""

    fileprivate func ingest(_ context: [String: Any]) {
        stale = context["stale"] as? Bool ?? false
        activeSessionId = context["activeSessionId"] as? String ?? ""
        depth = context["depth"] as? Int ?? 2
        overall = context["overall"] as? String ?? "idle"
        statusProject = context["statusProject"] as? String ?? ""
        sessions = (context["sessions"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return WatchSession(id: id, projectId: $0["projectId"] as? String ?? "",
                                projectName: $0["projectName"] as? String ?? ($0["projectId"] as? String ?? ""),
                                status: $0["status"] as? String ?? "idle",
                                depth: $0["depth"] as? Int ?? 2,
                                snippet: $0["snippet"] as? String ?? "")
        }
        pending = (context["pending"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let sid = $0["sessionId"] as? String else { return nil }
            return WatchPending(id: id, sessionId: sid,
                                projectName: $0["projectName"] as? String ?? "",
                                toolName: $0["toolName"] as? String ?? "?",
                                summary: $0["summary"] as? String ?? "",
                                risky: $0["risky"] as? Bool ?? false)
        }
        ComplicationState.write(overall: overall, stale: stale, activeProject: statusProject)
        // watchOS review #8: don't burn the complication reload budget on bursty state.
        if overall != lastOverall || Date().timeIntervalSince(lastReloadAt) > 30 {
            lastOverall = overall
            lastReloadAt = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Plays the alert haptic exactly once per alertId, whichever channel lands first.
    fileprivate func handleAlert(in payload: [String: Any], viaQueue: Bool) {
        guard let alertId = payload["alertId"] as? String,
              let kind = payload["kind"] as? String,
              !playedAlertIds.contains(alertId) else { return }
        playedAlertIds.append(alertId)
        if playedAlertIds.count > 50 { playedAlertIds.removeFirst(playedAlertIds.count - 50) }

        switch kind {
        case "needsInput": WKInterfaceDevice.current().play(.notification)
        case "complete": WKInterfaceDevice.current().play(.success)
        case "error": WKInterfaceDevice.current().play(.failure)
        default: break
        }

        // FR-023: queued delivery may land while the app is backgrounded — raise a
        // watch-local time-sensitive notification so the wrist alert doesn't depend on
        // the phone's lock state. (Fully-suspended delivery remains APNs / T043.)
        if viaQueue, kind == "needsInput", WKApplication.shared().applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = "\(payload["projectName"] as? String ?? "Claude") needs input"
            content.body = payload["summary"] as? String ?? ""
            content.threadIdentifier = payload["sessionId"] as? String ?? ""
            content.interruptionLevel = .timeSensitive
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: alertId, content: content, trigger: nil))
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in if !context.isEmpty { self.ingest(context) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.ingest(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Live channel: state (+ optional alert) while both apps are foregrounded.
        if message["state"] != nil {
            Task { @MainActor in
                self.ingest(message)
                self.handleAlert(in: message, viaQueue: false)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Queued channel (transferUserInfo): guaranteed-eventual state + alerts.
        if userInfo["state"] != nil {
            Task { @MainActor in
                self.ingest(userInfo)
                self.handleAlert(in: userInfo, viaQueue: true)
            }
        }
    }
}

// ComplicationState lives in Shared/Models.swift so the widget extension target can see it.
