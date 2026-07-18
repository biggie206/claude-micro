# Implementation Plan: Claude Micro — iPhone + Apple Watch Controller for Claude Sessions

**Branch**: `001-claude-micro` | **Date**: 2026-07-18 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-claude-micro/spec.md`

## Summary

Recreate the Work Louder Codex Micro control surface in software: a Mac-resident
companion server (Node/TS + Claude Agent SDK) owns real Claude Code sessions and exposes
a token-authenticated WebSocket protocol; a SwiftUI iPhone app renders the Micro-style
control pad (accept/reject/PTT/interrupt/skill pad/depth dial) over that socket; a
watchOS app relays through the phone via WatchConnectivity, mapping the Digital Crown to
thinking depth, the Action button (App Intent) to context-aware approve/PTT, and a
WidgetKit complication + haptics to agent status.

## Technical Context

**Language/Version**: TypeScript 5 / Node 18+ (server); Swift 5.10 / SwiftUI (clients)
**Primary Dependencies**: `@anthropic-ai/claude-agent-sdk`, `ws`, `zod` (server);
WatchConnectivity, WidgetKit, App Intents, Speech, AVFoundation (Apple); XcodeGen (project generation)
**Storage**: None (in-memory + SDK's on-disk session transcripts under `~/.claude/projects/`); JSON config file for projects/skills/token
**Testing**: vitest (server unit + protocol tests); XCTest (clients); manual acceptance per user story
**Target Platform**: macOS 14+ (server), iOS 17+ (iPhone 12 Pro Max), watchOS 10+ (Ultra 2; Action button requires watchOS 11+)
**Project Type**: Mobile + API (server/ + apple/ with iOS and watchOS targets)
**Performance Goals**: permission request → watch actionable < 3s LAN; first streamed token < 1s after SDK emit; crown depth ack < 2s
**Constraints**: TN3135 (no watch sockets → WatchConnectivity relay); Action button only via App Intents; SFSpeechRecognizer unavailable on watchOS; watch battery ≤5%/8h (SC-005)
**Scale/Scope**: single user, ≤ ~8 concurrent sessions, 2 client devices

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Glanceable interrupts | PASS | All watch interactions are single-gesture; text limited to one-line summaries |
| II. Server owns state | PASS | Snapshot-then-delta protocol; clients stateless renderers |
| III. Spec-driven | PASS | This artifact set; `/speckit.analyze` before implement |
| IV. Platform rules | PASS | TN3135 relay design; App Intent for Action button; no private APIs |
| V. Safe by default | PASS | No auto-approve; per-tool always-allow; token + loopback/Tailscale bind |
| VI. Degrade gracefully | PASS | Stale-state marking; reconnect w/ backoff; watch-without-phone shows explicit state |

## Project Structure

### Documentation (this feature)

```
specs/001-claude-micro/
├── spec.md
├── plan.md              # this file
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── websocket-protocol.md
└── tasks.md             # Phase 2 (/speckit.tasks)
```

### Source Code (repository root)

```
server/                      # Mac-resident companion server
├── package.json
├── tsconfig.json
├── claude-micro.config.json # projects allowlist, skills, token, bind addr
└── src/
    ├── index.ts             # WS server, auth, command router
    ├── protocol.ts          # zod schemas: commands & events (mirrors contracts/)
    ├── session.ts           # MicroSession: query()-per-turn wrapper, permission bridge
    ├── session-manager.ts   # registry, active session, snapshots
    └── depth.ts             # DepthLevel → SDK thinking config

apple/
├── project.yml              # XcodeGen → ClaudeMicro.xcodeproj (3 targets)
├── Shared/                  # compiled into both iOS & watchOS targets
│   ├── Models.swift         # Codable mirror of protocol.ts
│   └── AppState.swift       # observable store (sessions, pending, depth)
├── iOS/
│   ├── ClaudeMicroApp.swift
│   ├── ServerConnection.swift   # URLSessionWebSocketTask client + reconnect
│   ├── WatchRelay.swift         # WCSession phone side
│   ├── PTTController.swift      # SFSpeechRecognizer hold-to-talk
│   └── Views/
│       ├── ControlPadView.swift # Micro-style key grid + status banner
│       ├── DepthDialView.swift  # rotary dial gesture
│       └── SessionsView.swift   # switcher + new session
├── WatchApp/
│   ├── ClaudeMicroWatchApp.swift
│   ├── PhoneLink.swift          # WCSession watch side
│   ├── WatchControlView.swift   # crown depth + approve/reject + dictation
│   └── PrimaryActionIntent.swift# Action button App Intent
└── WatchWidget/
    └── StatusComplication.swift # WidgetKit accessory families
```

**Structure Decision**: Mobile + API split. `apple/Shared` is source-shared (not a Swift
package) to keep XcodeGen config trivial; promote to a local SPM package if it grows.

## Architecture & Data Flow

```
┌────────── Mac ──────────┐      WebSocket (JSON, token)      ┌── iPhone 12 Pro Max ──┐
│ claude-micro server     │ ◄───────────────────────────────► │ ClaudeMicro app       │
│  ├─ SessionManager      │   events: snapshot/state/delta/   │  ├─ ServerConnection  │
│  ├─ MicroSession ──────►│   permission_request/result       │  ├─ ControlPad + Dial │
│  │   Claude Agent SDK   │   cmds: prompt/approve/deny/      │  ├─ PTT (SFSpeech)    │
│  │   (user's ~/.claude) │   interrupt/set_depth/…           │  └─ WatchRelay (WC)   │
│  └─ per-turn query()    │                                    └──────────┬────────────┘
│      resume: sessionId  │                                    WatchConnectivity
└─────────────────────────┘                                   (appContext = state,
                                                                sendMessage = commands)
                                                               ┌── Watch Ultra 2 ──────┐
                                                               │  ├─ Crown → depth     │
                                                               │  ├─ ActionBtn intent  │
                                                               │  ├─ Dictation PTT     │
                                                               │  └─ Complication+hapt │
                                                               └───────────────────────┘
```

Turn lifecycle: client `prompt` → server starts `query()` (`resume`, `thinking` from
current depth, `canUseTool` bridge, `includePartialMessages`) → streams `assistant_delta`
/ `tool_activity` → on `canUseTool`, emits `permission_request` and awaits a client
`approve`/`deny` (Promise held in a pending map) → `result` event with cost/duration →
status back to idle.

## Phase Log

- **Phase 0 (research)**: complete → [research.md](./research.md)
- **Phase 1 (design & contracts)**: complete → [data-model.md](./data-model.md),
  [contracts/websocket-protocol.md](./contracts/websocket-protocol.md),
  [quickstart.md](./quickstart.md)
- **Phase 2 (tasks)**: complete → [tasks.md](./tasks.md)
- **Implementation status**: scaffold generated for server + all Apple targets; remaining
  work tracked in tasks.md (notably: Xcode signing, APNs stretch, TestFlight).
- **2026-07-18 implementation pass** (Claude Code):
  - `/speckit.analyze` run (T045): 8 findings fixed — Constitution V distinct risky-approve
    gesture added (phone + watch confirmation dialogs); FR-003 `permissionTimeoutMs`
    implemented server-side; contract `list_projects` reply corrected to `snapshot`;
    `interrupted` added to status semantics; Action-button pending scoped to active
    session (spec Edge Cases); T004 marked done; T046 added (restart re-list); data-model
    config example aligned.
  - T005 done: `npm install` + `tsc` green. Config created (48-char token, loopback bind,
    `claude-micro` project).
  - T021/T022 done: live socket E2E (bad-token 4401, Bash gate → approve → resume,
    double-approve → `already_resolved`); 18 vitest tests green.
  - T006 nearly done: xcodegen generates cleanly (`WKApplication` added to watch Info.plist);
    after Xcode 26.6 install, `ClaudeMicro` (iOS Simulator) and `ClaudeMicroWatch`
    (watchOS Simulator) both **BUILD SUCCEEDED** with zero Swift errors; only manual
    signing clicks remain (team + App Group on watch targets).
  - Post-review pass: 8 confirmed review findings fixed (gitignore token leak risk, risky
    one-tap bypass on grid key, stale dialog rebind on both platforms, Action-button/card
    divergence, timeout race surfacing, doc placement, timer leak).
  - T047 UI/UX+perf: ATS `NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription`
    (ws:// to LAN was ATS-blocked), WatchConnectivity context throttling for SC-005
    (significant changes immediate, token churn coalesced to ≤1/s), control-pad press
    haptics/disabled states/empty states/accessibility, transcript autoscroll, dial
    gesture rework with detent haptics, session rows with relative time+cost, app icons
    (generated dial motif) on both apps.
  - T048 security: git history verified secret-free; constant-time token compare;
    1 MiB WS maxPayload; socket error handlers (crash-DoS); quickstart no longer
    suggests `0.0.0.0` bind; MIT LICENSE added; iOS token moved to Keychain
    (migration deletes the legacy UserDefaults copy only after a verified round-trip).
  - Bridge refactor (owner direction change, 2026-07-18): phone control pad retired —
    the official Claude app covers rich phone control, so the wrist is the product.
    iPhone app reduced to BridgeHomeView (relay + status + pending-gate safety card +
    QR pairing + grant management + actionable notifications). Spec FR-005/009/012/014
    and US2 amended; T057. Signing (team S4XWNBC3N9) + watch App Group entitlements
    pinned in project.yml so xcodegen regeneration preserves them.
  - Robustness pass (FR-021, T046/T056): boot-time re-listing of resumable on-disk
    sessions (idle "(resumable)", capped/project, next prompt resumes with context),
    server-side heartbeat culling dead sockets, SIGINT/SIGTERM graceful shutdown
    (interrupt turns → `shutting_down` notice → 1001 close). 41 server tests.
  - UX pass 2 (FR-019/020, T054/T055): actionable needs-input notifications (Approve
    requires device auth; risky requests carry no Approve action and route to the in-app
    confirmation), client outbox retry over reconnect, QR pairing (`npm run pair`
    prints a claudemicro://pair QR preferring the Tailscale IP; iOS VisionKit scanner
    in Settings fills URL + Keychain token).
  - Security hardening pass (FR-015..018, T049–T053): grant-ordering hole closed (risky
    never satisfied by standing grants; `always` ignored on risky), grants surfaced in
    session state + `revoke_grant` + iOS Settings UI, append-only permission audit log,
    named per-device tokens, handshake timeout / unauth cap / bad-token backoff /
    Origin+Host validation, `startServer()` refactor with 10 WS integration tests,
    SECURITY.md, npm audit CI gate, dependabot, SDK pinned 0.1.77. Multi-provider
    (Codex/Gemini) expansion researched then cancelled by owner ("too much lift").
  - Review loop round 1 (8-angle small review): consolidated risky-approval dialog into
    one `riskyApprovalDialog` chokepoint; watch pushes now gated by event relevance at
    ServerConnection (relay throttle machinery deleted); stale `riskyToConfirm` pruned
    when its request resolves elsewhere; depth-dial anchor moved to @GestureState;
    shared pre-warmed haptic generators; `riskTint` semantic color; lastError cleared
    on reconnect; Keychain migration verified-before-delete.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| Watch relays via phone instead of direct connection | TN3135 forbids watch sockets | Direct HTTPS polling allowed but violates SC-005 battery budget and adds seconds of latency |
| Per-turn `query()` + resume instead of one streaming-input session | Thinking config is fixed at query start; dial must apply per-turn | Streaming-input mode would make depth changes impossible without killing the stream anyway |
