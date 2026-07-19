// Codable mirror of server/src/protocol.ts (protocol v1).
import SwiftUI

enum SessionStatus: String, Codable {
    case idle, thinking, working, needsInput = "needs_input", complete, error, interrupted

    /// RGB-lighting analog (contracts/websocket-protocol.md "Status semantics").
    var color: Color {
        switch self {
        case .idle: .gray
        case .thinking: .purple
        case .working: .blue
        case .needsInput: .orange
        case .complete: .green
        case .error: .red
        case .interrupted: .yellow
        }
    }

    var label: String {
        switch self {
        case .needsInput: "Needs input"
        default: rawValue.capitalized
        }
    }
}

struct Session: Codable, Identifiable, Equatable {
    let id: String
    let projectId: String
    let cwd: String
    var status: SessionStatus
    var depth: Int
    var active: Bool
    var grants: [String]   // always-allowed tools, session-scoped (FR-016)
    var lastSnippet: String
    var costUSD: Double
    let startedAt: String
    var lastActivityAt: String
}

struct PendingPermission: Codable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    let toolName: String
    let inputSummary: String
    let risky: Bool
    let requestedAt: String

    /// Severity tint used consistently across card, border, and labels.
    var riskTint: Color { risky ? .red : .orange }
}

struct Project: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let cwd: String
}

enum DepthLevel: Int, CaseIterable {
    case off = 0, light, standard, deep, max
    var label: String {
        switch self {
        case .off: "Off"; case .light: "Light"; case .standard: "Standard"
        case .deep: "Deep"; case .max: "Max"
        }
    }
}

/// Watch-app ↔ widget-extension bridge for complication state.
/// Uses an App Group container (add "group.com.tomnguyen.claudemicro" capability to both
/// watch targets in Xcode; falls back to standard defaults in the simulator/scaffold).
enum ComplicationState {
    static let key = "complicationState"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.com.tomnguyen.claudemicro") ?? .standard
    }
    static func write(overall: String, stale: Bool, activeProject: String) {
        defaults.set(["overall": overall, "stale": stale, "project": activeProject,
                      "writtenAt": Date().timeIntervalSince1970], forKey: key)
    }
    /// Constitution VI: entries age — a complication with no fresh write must show stale,
    /// never last-known status as live.
    static func read(maxAge: TimeInterval = 20 * 60) -> (overall: String, stale: Bool, project: String) {
        let d = defaults.dictionary(forKey: key) ?? [:]
        let writtenAt = d["writtenAt"] as? TimeInterval ?? 0
        let aged = Date().timeIntervalSince1970 - writtenAt > maxAge
        return (d["overall"] as? String ?? "idle",
                (d["stale"] as? Bool ?? true) || aged,
                d["project"] as? String ?? "")
    }
}

// MARK: - Server events (server → client)

enum ServerEvent: Decodable {
    case snapshot(sessions: [Session], pending: [PendingPermission], projects: [Project], activeSessionId: String?)
    case sessionState(Session)
    case assistantDelta(sessionId: String, text: String)
    case toolActivity(sessionId: String, toolName: String, summary: String)
    case permissionRequest(PendingPermission)
    case permissionResolved(requestId: String, resolution: String, by: String)
    case turnResult(sessionId: String, subtype: String, costUSD: Double, durationMs: Double, summary: String)
    case serverError(code: String, message: String, sessionId: String?)
    case pong(t: Double)

    private enum CodingKeys: String, CodingKey {
        case type, sessions, pending, projects, activeSessionId, session, sessionId, text,
             toolName, summary, request, requestId, resolution, by, subtype, costUSD,
             durationMs, code, message, t
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot":
            self = .snapshot(
                sessions: try c.decode([Session].self, forKey: .sessions),
                pending: try c.decode([PendingPermission].self, forKey: .pending),
                projects: try c.decode([Project].self, forKey: .projects),
                activeSessionId: try c.decodeIfPresent(String.self, forKey: .activeSessionId))
        case "session_state":
            self = .sessionState(try c.decode(Session.self, forKey: .session))
        case "assistant_delta":
            self = .assistantDelta(sessionId: try c.decode(String.self, forKey: .sessionId),
                                   text: try c.decode(String.self, forKey: .text))
        case "tool_activity":
            self = .toolActivity(sessionId: try c.decode(String.self, forKey: .sessionId),
                                 toolName: try c.decode(String.self, forKey: .toolName),
                                 summary: try c.decode(String.self, forKey: .summary))
        case "permission_request":
            self = .permissionRequest(try c.decode(PendingPermission.self, forKey: .request))
        case "permission_resolved":
            self = .permissionResolved(requestId: try c.decode(String.self, forKey: .requestId),
                                       resolution: try c.decode(String.self, forKey: .resolution),
                                       by: try c.decode(String.self, forKey: .by))
        case "turn_result":
            self = .turnResult(sessionId: try c.decode(String.self, forKey: .sessionId),
                               subtype: try c.decode(String.self, forKey: .subtype),
                               costUSD: try c.decode(Double.self, forKey: .costUSD),
                               durationMs: try c.decode(Double.self, forKey: .durationMs),
                               summary: try c.decode(String.self, forKey: .summary))
        case "error":
            self = .serverError(code: try c.decode(String.self, forKey: .code),
                                message: try c.decode(String.self, forKey: .message),
                                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId))
        case "pong":
            self = .pong(t: try c.decode(Double.self, forKey: .t))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type")
        }
    }
}

// MARK: - Client commands (client → server)

enum ClientCommand {
    case hello(token: String, device: String, name: String)
    case createSession(projectId: String, depth: Int?)
    case setActive(sessionId: String)
    case prompt(sessionId: String, text: String, source: String)
    case approve(sessionId: String, requestId: String, always: Bool)
    case deny(sessionId: String, requestId: String, message: String?)
    case interrupt(sessionId: String)
    case setDepth(sessionId: String?, level: Int)
    case skill(sessionId: String?, direction: String)
    case revokeGrant(sessionId: String, toolName: String)
    case ping(t: Double)

    var json: [String: Any] {
        var d: [String: Any] = ["v": 1]
        switch self {
        case let .hello(token, device, name):
            d["type"] = "hello"; d["token"] = token; d["device"] = device; d["name"] = name
        case let .createSession(projectId, depth):
            d["type"] = "create_session"; d["projectId"] = projectId
            if let depth { d["depth"] = depth }
        case let .setActive(sessionId):
            d["type"] = "set_active"; d["sessionId"] = sessionId
        case let .prompt(sessionId, text, source):
            d["type"] = "prompt"; d["sessionId"] = sessionId; d["text"] = text; d["source"] = source
        case let .approve(sessionId, requestId, always):
            d["type"] = "approve"; d["sessionId"] = sessionId; d["requestId"] = requestId
            if always { d["always"] = true }
        case let .deny(sessionId, requestId, message):
            d["type"] = "deny"; d["sessionId"] = sessionId; d["requestId"] = requestId
            if let message { d["message"] = message }
        case let .interrupt(sessionId):
            d["type"] = "interrupt"; d["sessionId"] = sessionId
        case let .setDepth(sessionId, level):
            d["type"] = "set_depth"; d["level"] = level
            if let sessionId { d["sessionId"] = sessionId }
        case let .skill(sessionId, direction):
            d["type"] = "skill"; d["direction"] = direction
            if let sessionId { d["sessionId"] = sessionId }
        case let .revokeGrant(sessionId, toolName):
            d["type"] = "revoke_grant"; d["sessionId"] = sessionId; d["toolName"] = toolName
        case let .ping(t):
            d["type"] = "ping"; d["t"] = t
        }
        return d
    }

    var encoded: Data { (try? JSONSerialization.data(withJSONObject: json)) ?? Data() }
}
