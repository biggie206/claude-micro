# Contract: Claude Micro WebSocket Protocol v1

Transport: WebSocket, JSON text frames. Endpoint: `ws://<mac-host>:8787/ws`.
Auth: first frame MUST be `hello` with the shared token; otherwise the server closes with
code `4401`. All messages carry `v: 1`.

Zod schemas in `server/src/protocol.ts` are the normative source; this document mirrors them.

## Client → Server (commands)

| type | payload | notes |
|---|---|---|
| `hello` | `{ token, device: "iphone"\|"watch"\|"other", name }` | must be first frame; reply `snapshot` |
| `create_session` | `{ projectId, depth? }` | projectId from config allowlist |
| `set_active` | `{ sessionId }` | routes subsequent contextual commands |
| `prompt` | `{ sessionId, text, source: "ptt"\|"typed"\|"skill" }` | starts a turn |
| `approve` | `{ sessionId, requestId, always?: boolean }` | `always` ⇒ per-tool+session allow |
| `deny` | `{ sessionId, requestId, message? }` | |
| `interrupt` | `{ sessionId }` | SDK `query.interrupt()` |
| `set_depth` | `{ sessionId?, level: 0..4 }` | omitted sessionId ⇒ active session; applies next turn |
| `skill` | `{ sessionId?, direction: "up"\|"down"\|"left"\|"right" }` | server expands binding → `prompt` |
| `list_projects` | `{}` | reply `snapshot` (projects are part of the snapshot; no separate event) |
| `ping` | `{ t }` | reply `pong { t }` |

## Server → Client (events)

| type | payload | notes |
|---|---|---|
| `snapshot` | `{ sessions: Session[], pending: PendingPermission[], projects: Project[], activeSessionId }` | on hello + on reconnect |
| `session_state` | `{ session: Session }` | any field change (status/depth/cost/active) |
| `assistant_delta` | `{ sessionId, text }` | streamed text chunks |
| `tool_activity` | `{ sessionId, toolName, summary }` | fires on tool_use blocks |
| `permission_request` | `{ request: PendingPermission }` | haptic-worthy |
| `permission_resolved` | `{ requestId, resolution: "allowed"\|"denied", by }` | broadcast to all clients |
| `turn_result` | `{ sessionId, subtype, costUSD, durationMs, summary }` | end of turn |
| `error` | `{ code, message, sessionId? }` | |
| `pong` | `{ t }` | |

## Shared shapes

```ts
Session = {
  id: string; projectId: string; cwd: string;
  status: "idle" | "thinking" | "working" | "needs_input" | "complete" | "error" | "interrupted";
  depth: 0|1|2|3|4; active: boolean;
  lastSnippet: string; costUSD: number; startedAt: string; lastActivityAt: string;
}
PendingPermission = {
  id: string; sessionId: string; toolName: string;
  inputSummary: string;          // one-line, ≤80 chars, pre-truncated server-side (watch glanceability)
  risky: boolean;                // destructive heuristic ⇒ distinct client gesture
  requestedAt: string;
}
Project = { id: string; name: string; cwd: string }
```

## Status semantics (RGB analog)

`idle` gray · `thinking` purple pulse · `working` blue · `needs_input` amber (haptic
`.notification`) · `complete` green (haptic `.success`) · `error` red (haptic `.failure`) ·
`interrupted` yellow (no haptic).

## Ordering & delivery guarantees

- Server serializes events per session; `permission_resolved` always follows its
  `permission_request`.
- Single-resolution: second `approve`/`deny` for the same `requestId` → `error
  { code: "already_resolved" }`.
- Clients MUST treat `snapshot` as authoritative and discard local pending state on receipt.

## WatchConnectivity mapping (phone ⇄ watch)

- Phone → watch `updateApplicationContext`: `{ sessions (compact), pending (compact), depth, activeSessionId, stale: Bool }` — latest-wins state mirror.
- Watch → phone `sendMessage`: `{ cmd: "approve"|"deny"|"prompt"|"set_depth"|"interrupt", ... }` — phone forwards over the socket verbatim and replies with delivery ack.
- Phone mirrors haptic-worthy events as `sendMessage` when watch reachable (instant haptic) and as local notification otherwise.
