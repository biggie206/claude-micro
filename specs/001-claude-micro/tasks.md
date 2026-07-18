# Tasks: Claude Micro — iPhone + Apple Watch Controller for Claude Sessions

**Input**: Design documents from `/specs/001-claude-micro/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Status legend**: `[x]` scaffolded in this repo · `[ ]` remaining (mostly Mac/Xcode-side)

## Format: `[ID] [P?] [Story] Description`

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 Create repo layout per plan.md (server/, apple/, specs/)
- [x] T002 [P] Init server package: `server/package.json`, `server/tsconfig.json` (Node 18, ESM, strict)
- [x] T003 [P] Author XcodeGen manifest `apple/project.yml` (iOS app, watch app, watch widget targets)
- [x] T004 On the Mac: `specify init --here --ai claude` to install .specify scripts/templates + /speckit.* commands (see research.md R7)
- [x] T005 On the Mac: `cd server && npm install && npm run build` — verify SDK + tsc green (2026-07-18: tsc exit 0)
- [ ] T006 On the Mac: `brew install xcodegen && cd apple && xcodegen` → open ClaudeMicro.xcodeproj, set signing team, add Speech/Mic usage strings (already in project.yml) — 2026-07-18: xcodegen + **both simulator builds BUILD SUCCEEDED** (Xcode 26.6, iOS/watchOS 26.5, zero Swift errors); only the manual signing clicks remain (team on 3 targets, App Group `group.com.tomnguyen.claudemicro` on both watch targets)

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL: No user story work can begin until this phase is complete**

- [x] T007 Define protocol schemas (zod) in `server/src/protocol.ts` per contracts/websocket-protocol.md
- [x] T008 Depth mapping `server/src/depth.ts` (DepthLevel → SDK thinking config)
- [x] T009 `server/src/session.ts` MicroSession: per-turn query() with resume, canUseTool bridge, status machine, delta events
- [x] T010 `server/src/session-manager.ts` registry, active session, snapshot builder
- [x] T011 `server/src/index.ts` WS server: hello/token auth, command router, broadcast, config load
- [x] T012 [P] Swift `apple/Shared/Models.swift` Codable mirror of protocol shapes
- [x] T013 [P] Swift `apple/Shared/AppState.swift` observable store (sessions, pending, depth, connection state)
- [x] T014 iOS `apple/iOS/ServerConnection.swift` WebSocket client + reconnect/backoff + snapshot handling
- [x] T015 iOS `apple/iOS/WatchRelay.swift` WCSession phone side (context push, command forward, haptic mirror)
- [x] T016 watch `apple/WatchApp/PhoneLink.swift` WCSession watch side (context decode, command send, haptics)

**Checkpoint**: server runs; phone connects and receives snapshot; watch mirrors state.

## Phase 3: User Story 1 — Approve/reject from the wrist (Priority: P1) 🎯 MVP

**Goal**: permission gate on Mac → actionable on watch/phone in <3s, single-resolution.
**Independent Test**: spec.md US1.

- [x] T017 [US1] Permission bridge: pending map + resolve semantics in `server/src/session.ts` (emit `permission_request`, enforce already_resolved)
- [x] T018 [US1] Risky-tool heuristic + inputSummary truncation in `server/src/session.ts`
- [x] T019 [P] [US1] iOS pending-request card + ✓/✕/Always buttons in `apple/iOS/Views/ControlPadView.swift`
- [x] T020 [P] [US1] Watch pending view + ✓/✕ + `.notification` haptic in `apple/WatchApp/WatchControlView.swift`
- [x] T021 [US1] E2E acceptance: run `npm run dev`, trigger Bash gate, approve from watch; verify SC-001 timing (2026-07-18: socket E2E verified — Bash gate → approve → resume + `already_resolved` on double-approve; watch-tap SC-001 timing still needs device, tracked in T035/T040 punch list)
- [x] T022 [US1] vitest: protocol round-trip + single-resolution tests in `server/test/` (2026-07-18: 18 tests green, incl. FR-003 timeout + always-allow + risky heuristic)

**Checkpoint**: MVP — US1 fully functional end-to-end.

## Phase 4: User Story 2 — Push-to-talk (Priority: P2)

- [x] T023 [US2] iOS `apple/iOS/PTTController.swift` SFSpeechRecognizer hold-to-talk with live partials
- [x] T024 [P] [US2] iOS PTT key (hold gesture, waveform/partial display) in ControlPadView
- [x] T025 [P] [US2] Watch dictation via TextFieldLink → `prompt` in WatchControlView
- [ ] T026 [US2] Empty-transcript guard test (AS-3) + mic/speech permission flows on device

## Phase 5: User Story 3 — Thinking-depth dial (Priority: P3)

- [x] T027 [US3] `set_depth` handling + apply-next-turn via resume (server, done in T008/T009)
- [x] T028 [P] [US3] Watch crown binding: digitalCrownRotation 0–4, detent haptics, 300ms debounce
- [x] T029 [P] [US3] iOS DepthDialView rotary gesture + level labels
- [ ] T030 [US3] Acceptance: verify depth reflected in next turn (SC-003); crown/phone convergence (AS-3)

## Phase 6: User Story 4 — Status at a glance (Priority: P3)

- [x] T031 [US4] Status→color/haptic mapping shared const in `apple/Shared/Models.swift`
- [x] T032 [P] [US4] WidgetKit complication `apple/WatchWidget/StatusComplication.swift` (circular/corner/rectangular)
- [x] T033 [P] [US4] iOS status banner (RGB analog) in ControlPadView
- [x] T034 [US4] Local-notification mirroring for backgrounded watch (phone side), complication reload wiring (in scaffold: `WatchRelay.notify` + `PhoneLink.ingest` → `WidgetCenter.reloadAllTimelines`; behavior verified on device under T035)
- [ ] T035 [US4] Haptic distinguishability test per SC-004

## Phase 7: User Story 5 — Sessions (Priority: P4)

- [x] T036 [US5] `create_session`/`set_active`/projects allowlist (server, done in T010/T011)
- [x] T037 [P] [US5] iOS SessionsView: cards, switcher, new-session sheet
- [x] T038 [US5] Watch session picker (list view, tap to set_active) (in scaffold: `WatchControlView.sessionPicker`)

## Phase 8: Action Button & Polish

- [x] T039 PrimaryActionIntent (approve-if-pending else dictation) in `apple/WatchApp/PrimaryActionIntent.swift`
- [ ] T040 On watch: Settings → Action Button → Shortcut → bind "Claude Primary Action"; verify launch→perform <30s path
- [x] T041 Skill pad 4-way swipe gestures on iOS (server `skill` command already implemented) (in scaffold: `ControlPadView.skillPad` DragGesture)
- [ ] T042 Tailscale docs + bind config for away-from-home use (quickstart.md §Remote)
- [ ] T043 [P] Stretch: APNs push for watch haptics when phone app killed
- [ ] T044 [P] Stretch: server as launchd agent (`com.claudemicro.server.plist`)
- [x] T045 Run /speckit.analyze; reconcile spec/plan/tasks drift; update Phase Log in plan.md (2026-07-18: 8 findings fixed — see plan.md Phase Log)
- [x] T046 Server restart recovery: re-list resumable sessions from `~/.claude/projects/` on boot as `idle (resumable)` (spec Edge Cases, FR-021) (2026-07-18: discovery + restore + tests)
- [x] T056 Liveness + graceful shutdown (FR-021): server-side WS ping/pong culling; SIGINT/SIGTERM → interrupt turns, `shutting_down` notice, clean close (2026-07-18: 6 tests incl. zombie-cull + 1001 close)
- [x] T047 UI/UX + performance polish pass within existing FRs (FR-005/006/009): animations/haptics/empty states/accessibility on iOS pad + watch, ATS/local-network Info.plist keys, WatchConnectivity context throttling (SC-005), app icons (2026-07-18: done, both simulator builds green)
- [x] T048 Pre-publication security review (repo going public): secrets scan incl. git history, auth/bind posture, LICENSE, docs accuracy (2026-07-18: history clean; hardened token compare/maxPayload/ws error handling; quickstart 0.0.0.0 guidance fixed; MIT LICENSE added; iOS token moved to Keychain with verified-before-delete migration)
- [x] T049 [Sec] Fix grant-ordering hole: risky check before alwaysAllow; ignore `always` on risky approvals (FR-016, server + test) (2026-07-18)
- [x] T050 [Sec] `startServer()` refactor + WS integration tests: auth (SC-006), handshake timeout, unauth cap, bad-token backoff, Origin/Host validation (FR-018) (2026-07-18: 10 integration tests green)
- [x] T051 [Sec] Append-only permission audit log (FR-015) + named multi-token auth (FR-017); pin SDK exact version (2026-07-18: SDK pinned 0.1.77)
- [x] T052 [Sec] Grants in session state + `revoke_grant` command (FR-016): protocol.ts, contract doc, Models.swift, iOS Settings grants UI (2026-07-18)
- [x] T053 [Sec] SECURITY.md + threat model; CI `npm audit` gate; dependabot (npm + actions) (2026-07-18)
- [x] T054 [US1] Actionable notifications (FR-019): category + Approve/Deny actions, risky = no Approve, notification-action → command forwarding, offline outbox flush on reconnect (2026-07-18: implemented + compiles; notification-action behavior still needs on-device verification alongside T026)
- [x] T055 [Setup] QR pairing (FR-020): server `--pair` QR emitter (pairHost/LAN detection) + iOS VisionKit scanner in Settings, `claudemicro://pair` parsing (2026-07-18: `npm run pair` renders QR live w/ Tailscale IP auto-detect; scan flow needs device camera)

## Dependencies & Execution Order

- Phase 1 → Phase 2 → story phases. US1 (Phase 3) blocks nothing after Phase 2 but is MVP.
- US2/US3/US4 depend only on Phase 2; parallelizable across server/iOS/watch files marked [P].
- T040 requires a physical Ultra 2 (Action button not in simulator). T021/T026/T030/T035 need devices.

## Implementation Strategy

MVP = Phases 1–3 (US1). Ship to TestFlight after Phase 4 (PTT makes it feel like the
Micro). Each later phase is independently shippable.
