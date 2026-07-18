# Security Policy

## Reporting

Please report suspected vulnerabilities privately via GitHub Security Advisories
(Security tab → "Report a vulnerability") on this repository. You should receive a
response within a week. Please do not open public issues for security reports.

## Threat model (summary)

Claude Micro's companion server is a **remote-control plane for code execution**: an
authenticated client can approve tool runs (including shell commands) inside allowlisted
project directories on the Mac that runs it.

**Trust boundary**
- *Trusted*: holders of a configured pairing token, connecting over loopback or a
  Tailscale-encrypted link.
- *Untrusted*: everything else — the LAN, the internet, browsers running on the Mac
  itself (WebSocket upgrades bearing an `Origin` header are rejected; `Host` is
  validated against IP-literal/localhost/allowlist to defeat DNS rebinding).

**Controls in place**
- Token auth on the first frame; constant-time comparison; per-device named tokens with
  individual revocation; exponential backoff on bad-token attempts; handshake timeout and
  a cap on concurrent unauthenticated sockets; 1 MiB frame cap.
- Server binds `127.0.0.1` by default; binding `0.0.0.0` is unsupported guidance.
- Permission gates are never auto-approved. Risky invocations (`rm -rf`, `sudo`,
  force-push, …) always re-prompt — standing "always allow" grants never satisfy them,
  grants are session-scoped, visible to clients, and revocable.
- Every permission resolution is written to an append-only audit log with the resolver's
  token identity and the full tool input.
- Claude credentials never leave the Mac; phones hold only the pairing token (stored in
  the iOS Keychain).

**Known non-goals / accepted risks**
- Plain-LAN `ws://` is cleartext; the supported mitigation is Tailscale (WireGuard).
  TLS (`wss://`) is on the roadmap, not implemented.
- The iOS app ships with `NSAllowsArbitraryLoads` (ATS open): Tailscale's CGNAT range is
  not "local networking" to ATS, and iOS ignores `NSAllowsArbitraryLoads` when any
  narrower exception key is present, so the open exception is the only way to reach the
  Mac over `ws://`. The link itself is token-authenticated and Tailscale-encrypted;
  replacing this with `wss://` + a scoped exception is tracked work.
- The pairing QR (`npm run pair`) encodes the pairing token — treat the terminal like a
  password field: pair on demand and clear scrollback afterward (the command prints a
  reminder). One-time pairing tokens are a candidate improvement.
- The audit log is written `0600`; it contains full tool inputs by design (forensics).
- The server trusts its local configuration file and the Claude Code installation on
  the same machine.
