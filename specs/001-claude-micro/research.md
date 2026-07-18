# Research: Claude Micro (Phase 0)

**Date**: 2026-07-18 | **Plan**: [plan.md](./plan.md)

## R1. How to programmatically control Claude sessions

**Decision**: Mac-resident companion server using `@anthropic-ai/claude-agent-sdk`
(TypeScript, Node 18+). One `query()` per user turn with `resume: sessionId` to preserve
context; `includePartialMessages: true` for streaming deltas.

**Rationale**: The Agent SDK is the supported programmatic interface to Claude Code — same
engine, same `~/.claude` auth (subscription credentials are picked up when no
`ANTHROPIC_API_KEY` is set), same CLAUDE.md/settings via `settingSources: ["project"]`.
claude.ai/Cowork sessions have no public control API, so "control Claude sessions" must
mean sessions the server owns.

**Alternatives considered**:
- Driving the interactive CLI via tmux scraping — brittle, no structured permission events.
- Anthropic Messages API directly — loses Claude Code tooling, permissions, CLAUDE.md.
- Browser automation of claude.ai — against ToS-adjacent, fragile, no push events.

**Key SDK facts verified (docs, July 2026)**:
- `query({ prompt, options }) → Query`; per-turn calls with `options.resume = sessionId`.
- Session id from `system/init` message (`message.session_id`) and `result` messages.
- Permission gates: `options.canUseTool: async (toolName, input, { signal, suggestions })`
  returning `{ behavior: "allow", updatedInput }` or `{ behavior: "deny", message }`.
- `permissionMode`: `default | acceptEdits | bypassPermissions | plan` (+ newer modes).
- `query.interrupt()` halts a running turn. `setPermissionMode`/`setModel` exist for
  streaming-input mode; not needed in per-turn-resume design.
- Thinking: `options.thinking = { type: "enabled"|"adaptive"|"disabled", budget_tokens }`
  (replaces `maxThinkingTokens`); set at query start → depth changes apply on next turn,
  which is exactly the dial semantics we want.
- Message stream: `system`, `assistant`, `user`, `result`, `stream_event` (raw deltas:
  `content_block_delta` with `text_delta` / `input_json_delta`).

## R2. Watch ↔ server transport

**Decision**: Watch never talks to the server directly. WatchConnectivity to the paired
iPhone: `updateApplicationContext` for state snapshots (latest-wins, delivered in
background), `sendMessage` for commands + live foreground updates. Phone holds the single
WebSocket to the server.

**Rationale**: Apple TN3135 — watchOS forbids low-level networking (WebSocket/NWConnection)
except audio-streaming/VoIP/DeviceDiscoveryUI cases; `URLSessionWebSocketTask` connections
fail on watchOS 9+ even in foreground. Plain HTTPS via URLSession is allowed but polling
burns battery (violates SC-005) and can't push.

**Alternatives considered**:
- HTTPS long-poll/SSE from the watch (allowed) — kept as documented fallback for
  phone-less operation; not v1.
- APNs direct to watch — stretch goal; requires server-side push infra + Apple Developer
  setup.

## R3. Action button integration (Watch Ultra 2)

**Decision**: Expose `PrimaryActionIntent` (App Intent, `openAppWhenRun = true`) in the
watch app target. User assigns it to the Action button via Settings → Action Button →
Shortcut. Behavior is context-aware: pending permission → approve; else → open dictation.

**Rationale**: There is no raw button-press API. App Intents via Shortcut assignment is
the only third-party path (watchOS 11+); workout-session "next action" intents don't fit
our domain. `perform()` runs after the system launches the app, so the intent reads
current state from the phone-synced store.

## R4. Digital Crown as thinking-depth dial

**Decision**: SwiftUI `.digitalCrownRotation($depth, from: 0, through: 4, by: 1,
sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)` on the focused
control view → 5 detents with system haptics; debounce 300ms then send `set_depth`.

**Depth → SDK mapping** (server-side, `depth.ts`):

| Detent | Label    | thinking config                              |
|--------|----------|----------------------------------------------|
| 0      | Off      | `{ type: "disabled" }`                        |
| 1      | Light    | `{ type: "enabled", budget_tokens: 4000 }`    |
| 2      | Standard | `{ type: "adaptive" }` (model decides)        |
| 3      | Deep     | `{ type: "enabled", budget_tokens: 24000 }`   |
| 4      | Max      | `{ type: "enabled", budget_tokens: 60000 }`   |

## R5. Voice input

**Decision**: iPhone PTT = `SFSpeechRecognizer` + `AVAudioEngine` (hold-to-talk, live
partials, on-device where available). Watch PTT = system dictation via SwiftUI
`TextFieldLink` (watchOS 9+) since `SFSpeechRecognizer` does not exist on watchOS; final
text only, no partials — acceptable for wrist use.

## R6. Status surface (RGB analog)

**Decision**: WidgetKit accessory complication (`accessoryCircular`, `accessoryCorner`,
`accessoryRectangular`) showing aggregate status color + active session name; timeline
reloaded from the watch app on state changes received via WatchConnectivity. Haptics via
`WKInterfaceDevice.current().play(_:)`: needs-input → `.notification`, complete →
`.success`, error → `.failure`, detent/confirm → `.click`.

**Constraint**: complication refresh budgets mean sub-minute latency isn't guaranteed when
the watch app is backgrounded; the reliable instant channel is the haptic fired by the
watch app when it receives a WatchConnectivity message (foreground) or a local
notification mirrored from the phone (background). Documented in spec edge cases.

## R7. Spec Kit conformance

**Decision**: Hand-authored artifacts match current spec-kit templates (spec/plan/tasks
structure, FR-###/SC-### ids, T### + [P] + [US#] task format). On the Mac, run
`uvx --from git+https://github.com/github/spec-kit.git specify init --here --ai claude`
inside the repo to layer in `.specify/scripts`, `.specify/templates`, and
`.claude/commands/speckit.*` without disturbing `specs/` — then `/speckit.analyze` and
`/speckit.implement` work natively in Claude Code CLI.
