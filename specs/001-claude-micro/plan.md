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

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| Watch relays via phone instead of direct connection | TN3135 forbids watch sockets | Direct HTTPS polling allowed but violates SC-005 battery budget and adds seconds of latency |
| Per-turn `query()` + resume instead of one streaming-input session | Thinking config is fixed at query start; dial must apply per-turn | Streaming-input mode would make depth changes impossible without killing the stream anyway |
