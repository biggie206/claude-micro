// Watch side of the WatchConnectivity bridge. TN3135: the watch never opens sockets;
// all state arrives via application context, all commands go out via sendMessage.
import Foundation
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
    @Published var stale = true

    struct WatchSession: Identifiable, Equatable {
        let id: String, projectId: String, status: String, depth: Int, snippet: String
    }
    struct WatchPending: Identifiable, Equatable {
        let id: String, sessionId: String, toolName: String, summary: String, risky: Bool
    }

    var oldestPending: WatchPending? {
        pending.first { $0.sessionId == activeSessionId } ?? pending.first
    }

    override private init() {
        super.init()
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

    private func send(_ payload: [String: Any]) {
        guard WCSession.default.isReachable else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        WCSession.default.sendMessage(payload, replyHandler: nil)
    }

    // MARK: state ingest

    fileprivate func ingest(_ context: [String: Any]) {
        stale = context["stale"] as? Bool ?? false
        activeSessionId = context["activeSessionId"] as? String ?? ""
        depth = context["depth"] as? Int ?? 2
        overall = context["overall"] as? String ?? "idle"
        sessions = (context["sessions"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return WatchSession(id: id, projectId: $0["projectId"] as? String ?? "",
                                status: $0["status"] as? String ?? "idle",
                                depth: $0["depth"] as? Int ?? 2,
                                snippet: $0["snippet"] as? String ?? "")
        }
        pending = (context["pending"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let sid = $0["sessionId"] as? String else { return nil }
            return WatchPending(id: id, sessionId: sid,
                                toolName: $0["toolName"] as? String ?? "?",
                                summary: $0["summary"] as? String ?? "",
                                risky: $0["risky"] as? Bool ?? false)
        }
        ComplicationState.write(overall: overall, stale: stale, activeProject: sessions.first { $0.id == activeSessionId }?.projectId ?? "")
        WidgetCenter.shared.reloadAllTimelines()
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
        // Instant haptic channel (US4): phone mirrors haptic-worthy events while we're reachable.
        guard let haptic = message["haptic"] as? String else { return }
        Task { @MainActor in
            switch haptic {
            case "needsInput": WKInterfaceDevice.current().play(.notification)
            case "complete": WKInterfaceDevice.current().play(.success)
            case "error": WKInterfaceDevice.current().play(.failure)
            default: break
            }
        }
    }
}

// ComplicationState lives in Shared/Models.swift so the widget extension target can see it.
