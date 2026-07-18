// Action button integration (Ultra 2). There is no raw button API: the user assigns this
// App Intent via Watch Settings → Action Button → Shortcut → "Claude Primary Action".
// Context-aware per spec FR-007: pending permission → approve; otherwise → open dictation.
import AppIntents
import SwiftUI
import WatchKit

struct PrimaryActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Claude Primary Action"
    static let description = IntentDescription(
        "Approves the pending Claude permission request if one is waiting; otherwise opens voice prompting.")
    /// System launches the watch app before perform() — required for reading live state.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared

        if let pending = link.actionButtonPending {
            guard !pending.risky else {
                // Constitution V: destructive tools need a deliberate on-screen gesture.
                WKInterfaceDevice.current().play(.failure)
                return .result(dialog: "Risky request — confirm on screen.")
            }
            link.approve(pending)
            return .result(dialog: "Approved \(pending.toolName).")
        }

        // Spec Edge Cases: the Action button only resolves the active session's pending.
        // If another session's request is what the screen is showing, say so instead of
        // silently opening dictation while a visible card waits.
        if link.oldestPending != nil {
            WKInterfaceDevice.current().play(.notification)
            return .result(dialog: "Pending on another session — confirm on screen.")
        }

        // No pending gate → signal the UI to open dictation (WatchControlView observes this).
        NotificationCenter.default.post(name: .openDictation, object: nil)
        return .result(dialog: "Listening…")
    }
}

extension Notification.Name {
    static let openDictation = Notification.Name("com.claudemicro.openDictation")
}

struct ClaudeMicroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PrimaryActionIntent(),
            phrases: ["Claude action in \(.applicationName)", "Approve Claude in \(.applicationName)"],
            shortTitle: "Claude Action",
            systemImageName: "button.programmable")
    }
}
