# Data Model: Claude Micro (Phase 1)

No persistent database. Server holds in-memory state; durable session history lives in the
Agent SDK's own transcripts (`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`), which
enables `resume` across server restarts.

## Entities

### Session
| field | type | notes |
|---|---|---|
| id | string (SDK session UUID) | assigned at first `system/init`; placeholder `pending-*` before |
| projectId | string | FK → Project (config) |
| cwd | string | absolute path on Mac |
| status | enum | idle, thinking, working, needs_input, complete, error, interrupted |
| depth | 0–4 | DepthLevel; applied to *next* turn |
| active | bool | exactly one active session per server |
| lastSnippet | string | last ≤120 chars of assistant text (session-card preview) |
| costUSD | number | cumulative from `result.total_cost_usd` |
| startedAt / lastActivityAt | ISO string | |

State transitions:
`idle → thinking` (turn starts) → `working` (first tool_use) ⇄ `needs_input`
(canUseTool pending) → `complete | error | interrupted` → `idle` (next prompt).

### PendingPermission
| field | type | notes |
|---|---|---|
| id | string (uuid) | requestId |
| sessionId | string | |
| toolName | string | e.g. `Bash`, `Edit` |
| input | object | full tool input (server-side only) |
| inputSummary | string ≤80 | derived, sent to clients |
| risky | bool | heuristic: Bash rm/force-push/sudo, Write outside cwd |
| resolver | Promise resolver | server-only; fulfills SDK canUseTool |
| resolution | allowed \| denied \| null | single-assignment |

### AlwaysAllowGrant
`(sessionId, toolName) → true` — consulted before emitting a request; session-scoped,
never persisted (Constitution V).

### DepthLevel (value object)
`0 Off · 1 Light(4k) · 2 Standard(adaptive) · 3 Deep(24k) · 4 Max(60k)` → SDK `thinking`
config (see research.md R4).

### Project (from `claude-micro.config.json`)
`{ id, name, cwd }` — allowlist of directories sessions may be created in (Constitution V).

### SkillBinding (config)
`{ up, down, left, right: { label, prompt } }` — expanded server-side into `prompt` turns.

### Config file schema (`server/claude-micro.config.json`)
```json
{
  "token": "generate-a-long-random-string",
  "bind": "127.0.0.1",
  "port": 8787,
  "defaultDepth": 2,
  "permissionTimeoutMs": null,
  "projects": [ { "id": "kbapp", "name": "LLM keyboard app", "cwd": "/Users/tom/code/llm-keyboard-app" } ],
  "skills": {
    "up":    { "label": "Review",  "prompt": "Review the current diff and summarize risks in 5 bullets." },
    "down":  { "label": "Commit",  "prompt": "Stage and commit the current work with a good message." },
    "left":  { "label": "Explain", "prompt": "Explain the last error and the fix you'd apply." },
    "right": { "label": "Test",    "prompt": "Run the test suite and fix any failures." }
  }
}
```

`permissionTimeoutMs` is a **top-level** config key (optional, default null = none): if
set, an unresolved PendingPermission is auto-denied after this many ms (FR-003). It is
not a per-project field.

## Client-side stores

- **iOS `AppState`**: mirrors snapshot + deltas; publishes to SwiftUI; forwards compact
  state to watch via `WatchRelay`.
- **watch `PhoneLink` store**: decodes application context; optimistic UI only for depth
  detents (reconciled by next context update); everything else server-authoritative.
