# Feature Specification: Claude Micro — iPhone + Apple Watch Controller for Claude Sessions

**Feature Branch**: `001-claude-micro`
**Created**: 2026-07-18
**Status**: Draft
**Input**: User description: "Build the Work Louder Codex Micro (https://worklouder.cc/codex-micro) experience, but as an iPhone 12 Pro Max app to control Claude sessions, plus an Apple Watch Ultra 2 app with functionality wired to the watch's buttons/dials."

## Overview

The Codex Micro is a 13-key hardware macro pad for driving OpenAI Codex agents: dedicated
accept/reject keys, push-to-talk voice prompting, a rotary dial for agent "thinking depth",
a joystick for skills, and RGB lighting that reflects agent status (idle / thinking /
complete / needs input / error). Claude Micro recreates that control surface in software:

| Codex Micro hardware        | Claude Micro equivalent                                        |
|-----------------------------|----------------------------------------------------------------|
| Accept / Reject keys        | Phone key grid buttons; Watch buttons; Action button (context) |
| Push-to-talk key            | Phone hold-to-talk key; Watch Action button → dictation        |
| Rotary dial (thinking depth)| Phone on-screen dial; Watch **Digital Crown** with haptic detents |
| Joystick (4-way skills)     | Phone swipe pad mapped to 4 custom skills/commands             |
| RGB status lighting         | Phone status banner colors; Watch complication + haptic taps   |
| 13 remappable keys / layers | Phone key grid with remappable actions (config on server)      |

Sessions are real Claude Code sessions running on the user's Mac (same auth, same repos,
same CLAUDE.md), owned by a Mac-resident companion server built on the Claude Agent SDK.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Approve or reject from the wrist (Priority: P1)

Tom kicked off a long refactor in a Claude session on his Mac and walked away. Claude hits
a permission gate (wants to run `npm test`). Tom's watch taps him; he raises his wrist,
sees "Bash: npm test", and presses the Action button (or taps ✓) to approve without
touching his Mac.

**Why this priority**: Permission gates are the single biggest reason agent runs stall.
Removing that stall from anywhere in the house is the core value proposition; every other
feature builds on the session/event plumbing this story requires.

**Independent Test**: Start a session via the server CLI, trigger a tool-permission
request, and verify the watch/phone receive it and can approve/deny it end-to-end with no
other features present.

**Acceptance Scenarios**:

1. **Given** a running session hits a tool permission gate, **When** the server emits the
   permission request, **Then** the phone shows it within 2s and the watch plays a
   distinct haptic and shows tool name + one-line summary.
2. **Given** a pending permission request is visible on the watch, **When** Tom presses
   the Action button, **Then** the request is approved, the session resumes, and the
   watch plays a success haptic.
3. **Given** a pending permission request, **When** Tom taps ✕ (deny), **Then** the session
   receives the denial with an optional canned reason and continues gracefully.
4. **Given** two clients see the same pending request, **When** one resolves it, **Then**
   the other updates to resolved state within 2s and cannot double-resolve.

---

### User Story 2 - Push-to-talk voice prompting (Priority: P2)

Tom holds the mic key on his phone (or presses the Action button on his watch when nothing
is pending), speaks "also add tests for the edge cases we discussed", releases, and the
transcribed prompt is sent into the active session.

**Why this priority**: PTT is the signature Codex Micro interaction and the main *input*
path when away from the keyboard, but it depends on Story 1's session plumbing.

**Independent Test**: With a session active, hold-to-talk on the phone, speak, release;
verify the transcript is delivered as the next user turn in the session.

**Acceptance Scenarios**:

1. **Given** an active session, **When** Tom holds the PTT key on iPhone and speaks,
   **Then** live transcription is shown while held, and on release the text is sent as a
   user prompt to the active session.
2. **Given** no pending permission request, **When** Tom presses the Action button on the
   watch, **Then** the watch opens dictation; the final transcript is sent to the active
   session on confirm.
3. **Given** a PTT transcript of zero length (accidental tap), **When** released, **Then**
   nothing is sent and no session state changes.

---

### User Story 3 - Thinking-depth dial via Digital Crown (Priority: P3)

Before firing off a gnarly architecture question, Tom rotates the Digital Crown up three
detents; the watch shows depth going from "Standard" to "Deep". His next prompt runs with
a larger thinking budget. For a trivial rename, he dials it down to "Off" for speed.

**Why this priority**: Faithful to the Micro's rotary dial and genuinely useful for
cost/latency control, but sessions work fine at a fixed default depth.

**Independent Test**: Change depth on the watch, send a prompt, verify the server started
the next turn with the corresponding thinking configuration.

**Acceptance Scenarios**:

1. **Given** the watch app is foregrounded, **When** Tom rotates the Digital Crown,
   **Then** depth steps through 5 detents (Off / Light / Standard / Deep / Max) with
   haptic feedback per detent, and the server confirms the new level within 2s.
2. **Given** depth was changed mid-session, **When** the next prompt is sent, **Then** the
   server applies the new thinking budget to that turn (via session resume) without
   losing conversation context.
3. **Given** the phone dial and the crown disagree transiently, **Then** last-write-wins
   at the server and all clients converge to the server's value.

---

### User Story 4 - Status at a glance (RGB equivalent) (Priority: P3)

Tom glances at his watch face: the Claude Micro complication is amber — a session needs
input. Distinct haptic patterns already told him this the moment it happened: one pattern
for "needs input", another for "run complete", another for "error".

**Why this priority**: The Micro's RGB lighting is its ambient-awareness layer; the
complication + haptics are the wearable analog. Depends only on Story 1 plumbing.

**Independent Test**: Drive a session through idle → thinking → needs-input → complete →
error states and verify complication color/text and haptic pattern per transition.

**Acceptance Scenarios**:

1. **Given** the complication is on the watch face, **When** any session enters
   needs-input, **Then** the complication reflects it on next timeline refresh and a
   `.notification` haptic fires (via the paired phone push → local notification path).
2. **Given** all sessions idle/complete, **Then** the complication shows green/idle state.
3. **Given** the server is unreachable, **Then** the complication shows a stale marker
   rather than the last live state.

---

### User Story 5 - Session switcher & new session (Priority: P4)

Tom has three repos with active sessions. On the phone he swipes between session cards
(status, repo name, last message snippet), taps one to make it active, or taps "+" to
start a fresh session in a chosen project directory.

**Why this priority**: Multi-session parity with the Micro's layers; single-session flows
already deliver the core value.

**Independent Test**: Create two sessions in different cwds, switch active session from
the phone, verify subsequent PTT/approve actions route to the newly active session.

**Acceptance Scenarios**:

1. **Given** N sessions exist, **When** the phone connects, **Then** it receives a
   snapshot of all N with status, cwd, and depth.
2. **Given** a configured project list, **When** Tom taps "+" and picks a project,
   **Then** the server spawns a session in that cwd and it becomes active.

---

### Edge Cases

- Permission request arrives while the watch is showing dictation → dictation continues;
  request queues; haptic fires after dictation dismisses.
- Two permission requests pending from different sessions → clients show a queue badge;
  Action button resolves the oldest for the *active* session only.
- Server restarts → clients auto-reconnect with exponential backoff; server re-lists
  resumable sessions from disk but marks them `idle (resumable)`, not live.
- Phone unreachable from watch (no WatchConnectivity) → watch shows "phone required"
  state; it does not attempt direct sockets (TN3135).
- Mid-turn interrupt while tokens are streaming → server calls SDK interrupt; clients
  show `interrupted` and the partial output is preserved.
- Dictation on watch returns emoji/non-text → non-text results discarded.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST run Claude sessions on the user's Mac via the Claude Agent
  SDK using the user's existing Claude Code credentials, with configurable project cwd.
- **FR-002**: The server MUST expose a token-authenticated WebSocket API carrying JSON
  commands (create/prompt/approve/deny/interrupt/set-depth/switch) and events (state,
  streaming text, permission requests, results) as defined in `contracts/websocket-protocol.md`.
- **FR-003**: The server MUST surface every SDK tool-permission callback as a
  `permission_request` event and block the tool until a client resolves it or a
  configurable timeout (default: none) elapses.
- **FR-004**: Clients MUST be able to approve, approve-always (per tool+session), or deny
  (with optional message) any pending permission request; the server MUST enforce
  single-resolution semantics.
- **FR-005**: The iPhone app MUST provide a Codex-Micro-style control pad: accept, reject,
  PTT (hold-to-talk with live transcription via SFSpeechRecognizer), interrupt, new
  session, session switcher, 4-way skill pad, and a thinking-depth dial.
- **FR-006**: The watch app MUST map the Digital Crown to thinking depth (5 detents,
  haptic per detent) while foregrounded.
- **FR-007**: The watch app MUST expose a `Primary Action` App Intent, assignable to the
  Ultra 2 Action button via Shortcuts, that approves the oldest pending permission for
  the active session if one exists, otherwise opens dictation for a voice prompt.
- **FR-008**: The watch MUST communicate exclusively through the paired iPhone via
  WatchConnectivity (application context for state; messages for commands); it MUST NOT
  open raw sockets (TN3135 compliance).
- **FR-009**: The system MUST reflect session status (idle / thinking / working /
  needs-input / complete / error) as: colored banner on iPhone, WidgetKit complication
  (accessoryCircular + accessoryCorner + accessoryRectangular) on watch, and distinct
  haptic patterns for needs-input, complete, and error transitions.
- **FR-010**: Thinking depth MUST map to SDK thinking configuration levels (Off / Light /
  Standard / Deep / Max) applied at the next turn via session resume, preserving context.
- **FR-011**: The server MUST support interrupting a running turn and starting a new
  session in any allowlisted project directory.
- **FR-012**: The 4-way skill pad MUST be remappable via server config (default: Up=/review
  changes, Down=/commit, Left=explain last error, Right=run tests).
- **FR-013**: The server MUST only bind to loopback and Tailscale interfaces by default
  and require the shared token on every connection.
- **FR-014**: All streaming assistant text MUST be delivered to the phone as deltas
  (target: first token visible < 1s after SDK emits it on LAN).
- **FR-015**: The server MUST keep an append-only audit log of every permission
  resolution (tool name, full tool input, risky flag, resolution, resolver identity,
  timestamp), enabled by default — approvals execute code and MUST be attributable.
- **FR-016**: Always-allow grants MUST be visible to clients (carried in session state)
  and revocable via a `revoke_grant` command. A risky invocation MUST never be satisfied
  by a standing grant, and an `always` flag on the approval of a risky request MUST be
  ignored server-side (Constitution V).
- **FR-017**: The server MUST support multiple named pairing tokens so an individual
  device can be revoked without re-pairing every device; resolver identity in events and
  the audit log MUST include the token name.
- **FR-018**: Connection hardening: unauthenticated sockets MUST be closed after a
  handshake timeout; concurrent unauthenticated connections MUST be capped; repeated
  bad-token attempts from one source address MUST back off exponentially; WebSocket
  upgrades bearing a browser `Origin` header MUST be rejected and the `Host` header
  validated against loopback/IP-literal/allowlisted names (DNS-rebinding defense).

### Key Entities

- **Session**: SDK session (id, cwd, status, depth, createdAt, lastActivity, costUSD).
- **PendingPermission**: (id, sessionId, toolName, inputSummary, requestedAt, resolution).
- **DepthLevel**: enum Off|Light|Standard|Deep|Max → SDK thinking config mapping.
- **SkillBinding**: direction → prompt/command template.
- **ClientDevice**: connected phone/watch (via phone relay), lastSeen.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A permission request raised on the Mac is actionable on the watch in under
  3 seconds on the same LAN, and a full approve round-trip (request → watch tap → session
  resumes) completes in under 5 seconds.
- **SC-002**: A user can run an entire agent turn lifecycle (voice prompt → monitor →
  approve gates → see completion) without touching the Mac, 10/10 attempts.
- **SC-003**: Crown depth changes register at the server in under 2 seconds and apply to
  100% of subsequent turns.
- **SC-004**: Status haptics are distinguishable: in a blind test the wearer identifies
  needs-input vs complete vs error correctly ≥ 90% of the time.
- **SC-005**: Watch battery impact ≤ 5% over an 8-hour workday of typical use (state via
  application context, no polling loops).
- **SC-006**: Zero unauthenticated commands accepted by the server in penetration smoke
  test (missing/wrong token → connection refused).

## Assumptions

- The Mac is awake and on the same LAN or reachable via Tailscale when remote control is
  expected. (Out of scope: waking the Mac remotely.)
- User has Claude Code installed and authenticated on the Mac (subscription or API key).
- iPhone 12 Pro Max on iOS 17+; Watch Ultra 2 on watchOS 10+ (Action button intents
  require watchOS 11+ for Shortcut assignment; degraded gracefully to on-screen buttons).
- APNs push (for haptics when the watch app is backgrounded) is a stretch goal; v1 relies
  on local notifications relayed through the phone while the phone app is running.
- Voice transcription happens on the iPhone (SFSpeechRecognizer) and via system dictation
  on the watch; no audio is sent to the companion server.
