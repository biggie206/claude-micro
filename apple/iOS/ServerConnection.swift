// WebSocket client to the Mac companion server, with reconnect + snapshot handling.
import Foundation
import Security
import UIKit

/// Keychain-backed storage for the pairing token (Constitution: clients hold only the
/// pairing token — and it should not sit in plaintext UserDefaults).
enum TokenStore {
    private static let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.tomnguyen.claudemicro",
        kSecAttrAccount as String: "server-token",
    ]

    static func load() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !token.isEmpty else { return }
        var q = baseQuery
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

@MainActor
final class ServerConnection: ObservableObject {
    @Published var lastError: String?

    private let state: AppState
    private let relay: WatchRelay
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var pingTimer: Timer?

    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "ws://192.168.1.10:8787/ws"
    @Published var token: String = TokenStore.load() ?? ""

    init(state: AppState, relay: WatchRelay) {
        self.state = state
        self.relay = relay
        relay.onCommand = { [weak self] cmd in self?.send(cmd) }   // watch → phone → server
        // One-time migration from the pre-Keychain UserDefaults slot. Only delete the
        // legacy copy once the Keychain round-trips — SecItemAdd can fail silently
        // (e.g. before first unlock) and the legacy slot is the sole durable copy.
        if token.isEmpty, let legacy = UserDefaults.standard.string(forKey: "serverToken") {
            token = legacy
            TokenStore.save(legacy)
        }
        if TokenStore.load() != nil { UserDefaults.standard.removeObject(forKey: "serverToken") }
    }

    func connect() {
        guard let url = URL(string: serverURL) else { lastError = "Bad server URL"; return }
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        TokenStore.save(token)
        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        send(.hello(token: token, device: "iphone", name: UIDevice.current.name))
        receiveLoop()
        startPing()
    }

    /// Commands worth retrying after a reconnect (FR-019: a notification-action approve
    /// often arrives while the socket is suspended). Pings/hellos are never queued.
    private var outbox: [ClientCommand] = []

    func send(_ command: ClientCommand) {
        guard let task else {
            queueForRetry(command)
            connect()
            return
        }
        task.send(.data(command.encoded)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.queueForRetry(command)
                    self?.handleDrop(error)
                }
            }
        }
    }

    private func queueForRetry(_ command: ClientCommand) {
        switch command {
        case .ping, .hello: return
        default:
            guard outbox.count < 8 else { return }
            outbox.append(command)
        }
    }

    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        let queued = outbox
        outbox = []
        queued.forEach { send($0) }   // late approvals resolve as already_resolved, surfaced on the pad
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(error)
                case .success(let message):
                    if self.reconnectAttempt > 0 { self.lastError = nil }   // recovered — drop stale drop-error
                    self.reconnectAttempt = 0
                    self.state.connected = true
                    if let data = Self.data(from: message),
                       let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
                        if case .snapshot = event { self.flushOutbox() }   // authed + converged
                        let haptic = self.state.apply(event)
                        // SC-005: only state transitions reach the watch — assistant_delta
                        // fires per streamed token but never changes watch-visible state.
                        if haptic != nil || Self.watchRelevant(event) {
                            self.relay.pushState(self.state, haptic: haptic)
                        }
                        if case let .serverError(code, message, _) = event {
                            self.lastError = "\(code): \(message)"
                        }
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    private func handleDrop(_ error: Error) {
        state.markDisconnected()
        relay.pushState(state, haptic: nil)
        lastError = error.localizedDescription
        pingTimer?.invalidate()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30)   // backoff, cap 30s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(.ping(t: Date().timeIntervalSince1970)) }
        }
    }

    private static func watchRelevant(_ e: ServerEvent) -> Bool {
        switch e {
        case .snapshot, .sessionState, .permissionRequest, .permissionResolved, .turnResult: true
        case .assistantDelta, .toolActivity, .serverError, .pong: false
        }
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let d): d
        case .string(let s): s.data(using: .utf8)
        @unknown default: nil
        }
    }
}
