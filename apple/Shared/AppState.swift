// Observable store shared by iOS and watchOS UIs. Server-authoritative (Constitution II):
// snapshots replace local state wholesale; deltas patch it.
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var pending: [PendingPermission] = []
    @Published var projects: [Project] = []
    @Published var activeSessionId: String?
    @Published var connected = false
    @Published var stale = true            // Constitution VI: never show stale as live

    var activeSession: Session? { sessions.first { $0.id == activeSessionId } ?? sessions.first { $0.active } }
    var activePending: PendingPermission? {
        let target = activeSession?.id
        return pending.sorted { $0.requestedAt < $1.requestedAt }.first { target == nil || $0.sessionId == target }
            ?? pending.sorted { $0.requestedAt < $1.requestedAt }.first
    }
    var overallStatus: SessionStatus {
        if pending.isEmpty == false { return .needsInput }
        if sessions.contains(where: { $0.status == .error }) { return .error }
        if sessions.contains(where: { $0.status == .thinking || $0.status == .working }) { return .working }
        if sessions.contains(where: { $0.status == .complete }) { return .complete }
        return .idle
    }

    func projectName(forSession sessionId: String) -> String {
        let projectId = sessions.first { $0.id == sessionId }?.projectId ?? ""
        return projects.first { $0.id == projectId }?.name ?? projectId
    }

    /// Apply a decoded server event. Returns the alert to raise, carrying the identity of
    /// the request/session that TRIGGERED it (FR-022: never rebuilt from "current pending").
    @discardableResult
    func apply(_ e: ServerEvent) -> AlertEvent? {
        stale = false
        switch e {
        case let .snapshot(sessions, pending, projects, activeSessionId):
            self.sessions = sessions
            self.pending = pending
            self.projects = projects
            self.activeSessionId = activeSessionId
            return nil
        case let .sessionState(session):
            let previous = sessions.first { $0.id == session.id }?.status
            if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session }
            else { sessions.append(session) }
            if session.active { activeSessionId = session.id }
            // FR-023: an error *status transition* is alert-worthy, not only error turn-results.
            if session.status == .error, previous != .error {
                return AlertEvent(kind: .error, sessionId: session.id,
                                  projectName: projectName(forSession: session.id),
                                  summary: session.lastSnippet, requestId: nil, risky: false)
            }
            return nil
        case .assistantDelta, .toolActivity:
            return nil   // bridge app renders no transcript (FR-014 amended); protocol keeps deltas
        case let .permissionRequest(request):
            if !pending.contains(where: { $0.id == request.id }) { pending.append(request) }
            return AlertEvent(kind: .needsInput, sessionId: request.sessionId,
                              projectName: projectName(forSession: request.sessionId),
                              summary: request.inputSummary, requestId: request.id, risky: request.risky)
        case let .permissionResolved(requestId, _, _):
            pending.removeAll { $0.id == requestId }
            return nil
        case let .turnResult(sessionId, subtype, _, _, summary):
            let kind: HapticSignal = subtype == "success" ? .complete : .error
            return AlertEvent(kind: kind, sessionId: sessionId,
                              projectName: projectName(forSession: sessionId),
                              summary: summary, requestId: nil, risky: false)
        case .serverError, .pong:
            return nil
        }
    }

    func markDisconnected() {
        connected = false
        stale = true
    }
}

enum HapticSignal: String { case needsInput, complete, error }

/// A haptic/alert-worthy event with the identity of what triggered it (FR-022/FR-023).
/// `id` is stable across delivery channels so the watch can de-duplicate.
struct AlertEvent {
    let id = UUID().uuidString
    let kind: HapticSignal
    let sessionId: String
    let projectName: String
    let summary: String
    let requestId: String?
    let risky: Bool

    var payload: [String: Any] {
        var d: [String: Any] = ["alertId": id, "kind": kind.rawValue, "sessionId": sessionId,
                                "projectName": projectName, "summary": summary, "risky": risky]
        if let requestId { d["requestId"] = requestId }
        return d
    }
}
