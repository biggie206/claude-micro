# Claude Micro Constitution

<!-- Managed via /speckit.constitution. Version bumps follow semver rules below. -->

## Core Principles

### I. Glanceable Interrupts First
Every core interaction (approve, reject, interrupt, voice prompt, depth change) MUST be
completable in under 3 seconds and without reading more than one line of text. The product
is an *interrupt surface*, not a chat client. Any feature that requires sustained reading
or typing on the watch violates this principle and belongs on the phone or the Mac.

### II. Server Owns All State; Clients Are Thin
The companion server (Mac-resident, Claude Agent SDK) is the single source of truth for
session state, pending permissions, and thinking depth. Phone and watch render state and
send commands; they MUST NOT cache authoritative state or make decisions the server could
make. Reconnecting clients receive a full state snapshot before any deltas.

### III. Spec-Driven Development (NON-NEGOTIABLE)
All feature work follows GitHub Spec Kit flow: constitution → specify → clarify → plan →
tasks → implement. No implementation lands without a corresponding FR/SC in
`specs/[###-feature]/spec.md`. Changes in direction amend the spec first, code second.

### IV. Platform Rules Are Constraints, Not Suggestions
Apple platform restrictions discovered in research (no raw WebSockets on watchOS per
TN3135, Action button reachable only through App Intents, SFSpeechRecognizer unavailable
on watchOS) MUST be designed around, never hacked around. Private API usage is forbidden.

### V. Safe by Default
Permission requests from Claude sessions are NEVER auto-approved by default. `always allow`
grants are per-tool, per-session, and explicit. Destructive-tool requests (Bash rm, git
push --force, etc.) MUST require a distinct confirmation gesture on the client. The server
binds to localhost/Tailscale interfaces only and requires a shared token.

### VI. Degrade Gracefully
Watch works without direct network via WatchConnectivity relay through the phone. Phone
works without the watch. If the Mac server is unreachable, clients show last-known state
clearly marked stale — never fabricated status.

## Additional Constraints

- Server: TypeScript, Node 18+, `@anthropic-ai/claude-agent-sdk`. No database; in-memory
  state + session resume via SDK session IDs on disk (`~/.claude/projects/...`).
- Apple targets: iOS 17+ (iPhone 12 Pro Max), watchOS 10+ (Watch Ultra 2), SwiftUI only.
- Transport: WebSocket (JSON) phone↔server; WatchConnectivity watch↔phone.
- Auth to Claude: the user's existing Claude Code credentials on the Mac (subscription or
  ANTHROPIC_API_KEY). Credentials never leave the Mac; clients hold only the pairing token.

## Development Workflow

- Feature branches named `###-feature-name` matching `specs/` directories.
- `/speckit.analyze` before `/speckit.implement` on every feature.
- Server changes require `npm run build` (tsc) green before commit; Swift changes require
  a successful Xcode build for both iOS and watchOS targets.

## Governance

This constitution supersedes ad-hoc practice. Amendments require a version bump and a note
in the Sync Impact Report at the top of this file. MAJOR: principle removals/redefinitions;
MINOR: new principles/sections; PATCH: clarifications.

**Version**: 1.0.0 | **Ratified**: 2026-07-18 | **Last Amended**: 2026-07-18
