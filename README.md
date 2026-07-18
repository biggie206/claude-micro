# Claude Micro

The [Work Louder Codex Micro](https://worklouder.cc/codex-micro), reimagined as software:
control **Claude Code sessions on your Mac** from an **iPhone 12 Pro Max** control pad and
an **Apple Watch Ultra 2** — Digital Crown as the thinking-depth dial, Action button as
context-aware approve / push-to-talk, complication + haptics as the RGB status lighting.

```
Mac (companion server, Claude Agent SDK)
 └─ WebSocket ── iPhone app (control pad, PTT, dial, sessions)
                  └─ WatchConnectivity ── Watch app (crown, Action button, haptics, complication)
```

## Layout

| Path | What |
|---|---|
| `specs/001-claude-micro/` | **GitHub Spec Kit** artifacts: spec, plan, research, data model, WS protocol contract, tasks |
| `.specify/memory/constitution.md` | Project constitution |
| `server/` | Node/TS companion server (typechecks clean; `npm run dev`) |
| `apple/` | XcodeGen manifest + SwiftUI sources for iOS app, watch app, watch complication |

## Start here

1. **Read** `specs/001-claude-micro/quickstart.md` — server up in ~5 min, apps in ~15.
2. **Spec Kit loop** (Claude Code CLI): `specify init --here --ai claude`, then
   `/speckit.analyze` → `/speckit.implement`. `specs/001-claude-micro/tasks.md` marks
   what's scaffolded `[x]` vs remaining `[ ]` (signing, on-device tests, APNs stretch).

## Codex Micro → Claude Micro mapping

| Micro hardware | Here |
|---|---|
| Accept / Reject keys | Phone keys · Watch ✓/✕ · **Action button** (when a gate is pending) |
| Push-to-talk key | Phone hold-to-talk (live transcription) · Watch Action button → dictation |
| Rotary dial (thinking depth) | Phone dial · **Digital Crown**, 5 detents w/ haptics, applies next turn |
| Joystick skills | 4-way swipe pad, server-remappable (`claude-micro.config.json`) |
| RGB status lighting | Status banner · watch complication · distinct haptic per event |
| Layers / remappable keys | Sessions switcher + config-driven skills |

## Security posture

- Token-authenticated WebSocket (constant-time compare); unauthenticated frames close the
  socket with `4401`. 1 MiB frame cap pre-auth.
- Server binds to loopback by default; use a specific LAN/Tailscale IP otherwise — never
  `0.0.0.0`. Tailscale encrypts the link; plain LAN is cleartext.
- Permission gates are never auto-approved; risky tools (rm -rf, force-push, sudo…)
  require a distinct confirmation gesture on every surface, including the Action button.
- The pairing token lives in the iOS Keychain; Claude credentials never leave the Mac.
- `claude-micro.config.json` (holds the token) is gitignored — copy the example to create it.

## Status

Server + both apps build clean and the protocol is exercised end-to-end
(`server/test/`, 18 tests). Remaining work is tracked in
`specs/001-claude-micro/tasks.md` — chiefly on-device verification (signing,
haptics, Action button) and stretch goals (APNs, launchd).

Built spec-first per the repo constitution. Protocol contract:
`specs/001-claude-micro/contracts/websocket-protocol.md`.

MIT licensed.
