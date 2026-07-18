// WebSocket client to the Mac companion server, with reconnect + snapshot handling.
import Foundation
import UIKit

@MainActor
final class ServerConnection: ObservableObject {
    @Published var lastError: String?

    private let state: AppState
    private let relay: WatchRelay
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var pingTimer: Timer?

    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "ws://192.168.1.10:8787/ws"
    @Published var token: String = UserDefaults.standard.string(forKey: "serverToken") ?? ""

    init(state: AppState, relay: WatchRelay) {
        self.state = state
        self.relay = relay
        relay.onCommand = { [weak self] cmd in self?.send(cmd) }   // watch → phone → server
    }

    func connect() {
        guard let url = URL(string: serverURL) else { lastError = "Bad server URL"; return }
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(token, forKey: "serverToken")
        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        send(.hello(token: token, device: "iphone", name: UIDevice.current.name))
        receiveLoop()
        startPing()
    }

    func send(_ command: ClientCommand) {
        task?.send(.data(command.encoded)) { [weak self] error in
            if let error { Task { @MainActor in self?.handleDrop(error) } }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(error)
                case .success(let message):
                    self.reconnectAttempt = 0
                    self.state.connected = true
                    if let data = Self.data(from: message),
                       let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
                        let haptic = self.state.apply(event)
                        self.relay.pushState(self.state, haptic: haptic)
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

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let d): d
        case .string(let s): s.data(using: .utf8)
        @unknown default: nil
        }
    }
}
