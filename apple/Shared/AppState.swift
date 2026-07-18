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
    @Published var transcript: [String: String] = [:]   // sessionId → streamed text (tail)

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

    /// Apply a decoded server event. Returns a haptic-worthy signal when one occurred.
    @discardableResult
    func apply(_ e: ServerEvent) -> HapticSignal? {
        stale = false
        switch e {
        case let .snapshot(sessions, pending, projects, activeSessionId):
            self.sessions = sessions
            self.pending = pending
            self.projects = projects
            self.activeSessionId = activeSessionId
            return nil
        case let .sessionState(session):
            if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session }
            else { sessions.append(session) }
            if session.active { activeSessionId = session.id }
            return nil
        case let .assistantDelta(sessionId, text):
            transcript[sessionId, default: ""] += text
            transcript[sessionId] = String(transcript[sessionId]!.suffix(4000))
            return nil
        case .toolActivity:
            return nil
        case let .permissionRequest(request):
            if !pending.contains(where: { $0.id == request.id }) { pending.append(request) }
            return .needsInput
        case let .permissionResolved(requestId, _, _):
            pending.removeAll { $0.id == requestId }
            return nil
        case let .turnResult(_, subtype, _, _, _):
            return subtype == "success" ? .complete : .error
        case .serverError, .pong:
            return nil
        }
    }

    func markDisconnected() {
        connected = false
        stale = true
    }
}

enum HapticSignal { case needsInput, complete, error }
