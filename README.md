# Claude Micro

[![CI](https://github.com/biggie206/claude-micro/actions/workflows/ci.yml/badge.svg)](https://github.com/biggie206/claude-micro/actions/workflows/ci.yml)

The [Work Louder Codex Micro](https://worklouder.cc/codex-micro), reimagined for the
wrist: control **Claude Code sessions on your Mac** from an **Apple Watch Ultra 2** —
Digital Crown as the thinking-depth dial, Action button as context-aware approve /
push-to-talk, complication + haptics as the RGB status lighting. The iPhone app is a
thin **bridge** (watchOS can't open sockets — TN3135): it relays the WebSocket, pairs
via QR, surfaces actionable approve/deny notifications, and manages always-allow grants.

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
| `apple/` | XcodeGen manifest + SwiftUI sources: watch app + complication (the product), iOS bridge app |

## Start here

1. **Read** `specs/001-claude-micro/quickstart.md` — server up in ~5 min, apps in ~15.
2. **Spec Kit loop** (Claude Code CLI): `specify init --here --ai claude`, then
   `/speckit.analyze` → `/speckit.implement`. `specs/001-claude-micro/tasks.md` marks
   what's scaffolded `[x]` vs remaining `[ ]` (signing, on-device tests, APNs stretch).

## Codex Micro → Claude Micro mapping

| Micro hardware | Here |
|---|---|
| Accept / Reject keys | Watch ✓/✕ · **Action button** (when a gate is pending) · phone notification actions |
| Push-to-talk key | Watch Action button → dictation |
| Rotary dial (thinking depth) | **Digital Crown**, 5 detents w/ haptics, applies next turn |
| Joystick skills | Server-remappable skill bindings (`claude-micro.config.json`) |
| RGB status lighting | Watch complication · distinct haptic per event · phone notifications |
| Layers / remappable keys | Watch session picker + config-driven skills |

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
