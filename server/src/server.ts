// Claude Micro companion server core — exported as startServer() so integration
// tests can boot it on an ephemeral port (index.ts is the CLI bootstrap).
import { timingSafeEqual } from "node:crypto";
import { appendFile } from "node:fs/promises";
import { createServer, type IncomingMessage } from "node:http";
import { isIP } from "node:net";
import { WebSocketServer, WebSocket } from "ws";
import { ClientCommand, event, PROTOCOL_VERSION, type ServerEvent } from "./protocol.js";
import { SessionManager } from "./session-manager.js";
import type { MicroSession, ResolutionAudit } from "./session.js";

export interface Config {
  /** Single shared token (legacy) — or use `tokens` for per-device revocability (FR-017). */
  token?: string;
  tokens?: { id: string; token: string }[];
  bind: string;
  port: number;
  defaultDepth: 0 | 1 | 2 | 3 | 4;
  permissionTimeoutMs?: number | null;
  /** Append-only JSONL audit log of permission resolutions (FR-015). false disables. */
  auditLog?: string | false;
  /** Extra Host header names accepted on upgrade (IP literals + localhost always pass). */
  allowedHosts?: string[];
  /** Test hooks; production defaults apply when omitted. */
  handshakeTimeoutMs?: number;
  maxUnauthedSockets?: number;
  projects: { id: string; name: string; cwd: string }[];
  skills: Record<"up" | "down" | "left" | "right", { label: string; prompt: string }>;
}

interface NamedToken { id: string; token: string }

export function namedTokens(config: Config): NamedToken[] {
  const list: NamedToken[] = [];
  if (config.token) list.push({ id: "shared", token: config.token });
  for (const t of config.tokens ?? []) list.push(t);
  return list;
}

export function validateConfig(config: Config): string | null {
  const tokens = namedTokens(config);
  if (tokens.length === 0) return "no token configured";
  for (const t of tokens) if (!t.token || t.token.length < 16) return `token "${t.id}" missing or too short (Constitution V)`;
  const ids = new Set(tokens.map((t) => t.id));
  if (ids.size !== tokens.length) return "duplicate token ids";
  return null;
}

/** Constant-time match against every configured token; returns the token's name. */
function matchToken(candidate: string, tokens: NamedToken[]): string | null {
  const a = Buffer.from(candidate);
  let matched: string | null = null;
  for (const t of tokens) {
    const b = Buffer.from(t.token);
    // Compare every token (no early exit) so timing doesn't reveal which id failed.
    if (a.length === b.length && timingSafeEqual(a, b) && matched === null) matched = t.id;
  }
  return matched;
}

/** FR-018: reject browser-origin upgrades and non-allowlisted Host names (DNS rebinding). */
export function upgradeAllowed(req: IncomingMessage, allowedHosts: string[]): boolean {
  if (req.headers.origin) return false; // native clients never send Origin; browsers always do
  const hostHeader = req.headers.host ?? "";
  const host = hostHeader.startsWith("[")
    ? hostHeader.slice(1, hostHeader.indexOf("]"))            // [ipv6]:port
    : hostHeader.split(":")[0];
  if (!host) return false;
  return host === "localhost" || isIP(host) !== 0 || allowedHosts.includes(host);
}

export function startServer(config: Config): { close: () => Promise<void>; port: () => number; ready: Promise<void> } {
  const configError = validateConfig(config);
  if (configError) throw new Error(`Refusing to start: ${configError}`);

  const tokens = namedTokens(config);
  const handshakeTimeoutMs = config.handshakeTimeoutMs ?? 10_000;
  const maxUnauthed = config.maxUnauthedSockets ?? 8;
  const allowedHosts = config.allowedHosts ?? [];

  const manager = new SessionManager(config.projects, config.defaultDepth, config.permissionTimeoutMs ?? null);
  const authed = new Map<WebSocket, { tokenId: string; device: string; name: string }>();
  let unauthedCount = 0;
  const badTokenBackoff = new Map<string, { fails: number; blockedUntil: number }>();

  const audit = (entry: Record<string, unknown>): void => {
    if (config.auditLog === false) return;
    const path = config.auditLog ?? new URL("../claude-micro-audit.jsonl", import.meta.url).pathname;
    appendFile(path, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n")
      .catch((err) => console.error("audit write failed:", err?.message ?? err));
  };

  const broadcast = (e: ServerEvent) => {
    const frame = event(e);
    for (const ws of authed.keys()) if (ws.readyState === WebSocket.OPEN) ws.send(frame);
  };

  function wireSession(session: MicroSession): void {
    session.on("state", () => broadcast({ v: 1, type: "session_state", session: session.toShape() }));
    session.on("delta", (text) => broadcast({ v: 1, type: "assistant_delta", sessionId: session.id, text }));
    session.on("tool", (toolName, summary) => broadcast({ v: 1, type: "tool_activity", sessionId: session.id, toolName, summary }));
    session.on("permission", (request) => broadcast({ v: 1, type: "permission_request", request }));
    session.on("permissionResolved", (requestId, resolution, by, a: ResolutionAudit) => {
      audit({ kind: "permission", sessionId: session.id, requestId, resolution, by,
              toolName: a.toolName, input: a.input, risky: a.risky, always: a.always });
      broadcast({ v: 1, type: "permission_resolved", requestId, resolution, by });
    });
    session.on("result", (subtype, costUSD, durationMs, summary) =>
      broadcast({ v: 1, type: "turn_result", sessionId: session.id, subtype, costUSD, durationMs, summary }));
  }

  const http = createServer((_req, res) => { res.writeHead(200); res.end("claude-micro ok\n"); });
  // maxPayload: unauthenticated peers must not be able to buffer huge frames (default is 100 MiB).
  const wss = new WebSocketServer({ server: http, path: "/ws", maxPayload: 1024 * 1024 });
  wss.on("error", (err) => console.error("wss error:", err.message));

  wss.on("connection", (ws, req) => {
    ws.on("error", () => ws.close()); // a socket error must never crash the server

    if (!upgradeAllowed(req, allowedHosts)) return ws.close(4403, "forbidden origin/host");

    const ip = req.socket.remoteAddress ?? "unknown";
    const backoff = badTokenBackoff.get(ip);
    if (backoff && Date.now() < backoff.blockedUntil) return ws.close(4429, "too many attempts");

    if (unauthedCount >= maxUnauthed) return ws.close(4401, "too many pending connections");
    unauthedCount++;
    let counted = true;
    const settleUnauthed = () => { if (counted) { counted = false; unauthedCount--; } };
    ws.once("close", settleUnauthed);

    const handshakeTimer = setTimeout(() => {
      if (!authed.has(ws)) ws.close(4401, "auth timeout");
    }, handshakeTimeoutMs);
    handshakeTimer.unref?.();

    const fail = (code: string, message: string) => ws.send(event({ v: 1, type: "error", code, message }));

    ws.on("message", (raw) => {
      let cmd: ClientCommand;
      try {
        cmd = ClientCommand.parse(JSON.parse(String(raw)));
      } catch {
        return fail("bad_message", "Failed to parse command (protocol v" + PROTOCOL_VERSION + ")");
      }

      const client = authed.get(ws);
      if (!client) {
        if (cmd.type !== "hello") return ws.close(4401, "hello first");
        const tokenId = matchToken(cmd.token, tokens);
        if (!tokenId) {
          const prev = badTokenBackoff.get(ip) ?? { fails: 0, blockedUntil: 0 };
          const fails = prev.fails + 1;
          badTokenBackoff.set(ip, { fails, blockedUntil: Date.now() + Math.min(60_000, 1000 * 2 ** fails) });
          audit({ kind: "auth_failed", ip, device: cmd.device, name: cmd.name });
          return ws.close(4401, "bad token");
        }
        badTokenBackoff.delete(ip);
        clearTimeout(handshakeTimer);
        settleUnauthed();
        authed.set(ws, { tokenId, device: cmd.device, name: cmd.name });
        audit({ kind: "auth_ok", ip, tokenId, device: cmd.device, name: cmd.name });
        return ws.send(event({ v: 1, type: "snapshot", ...manager.snapshot() }));
      }
      const identity = `${client.tokenId}/${client.device}:${client.name}`;

      try {
        switch (cmd.type) {
          case "hello":
            return ws.send(event({ v: 1, type: "snapshot", ...manager.snapshot() }));
          case "ping":
            return ws.send(event({ v: 1, type: "pong", t: cmd.t }));
          case "list_projects":
            return ws.send(event({ v: 1, type: "snapshot", ...manager.snapshot() }));
          case "create_session": {
            const session = manager.create(cmd.projectId, cmd.depth);
            wireSession(session);
            return broadcast({ v: 1, type: "snapshot", ...manager.snapshot() });
          }
          case "set_active": {
            if (!manager.setActive(cmd.sessionId)) return fail("unknown_session", cmd.sessionId);
            return broadcast({ v: 1, type: "snapshot", ...manager.snapshot() });
          }
          case "prompt": {
            const session = manager.get(cmd.sessionId);
            if (!session) return fail("unknown_session", cmd.sessionId);
            if (!cmd.text.trim()) return; // FR: empty PTT is a no-op
            session.prompt(cmd.text).catch((err) =>
              fail(err?.message === "turn_in_progress" ? "turn_in_progress" : "turn_failed", String(err?.message ?? err)));
            return;
          }
          case "approve":
          case "deny": {
            const session = manager.get(cmd.sessionId);
            if (!session) return fail("unknown_session", cmd.sessionId);
            const resolution = cmd.type === "approve" ? "allowed" : "denied";
            const ok = session.resolvePermission(cmd.requestId, resolution, identity, {
              always: cmd.type === "approve" ? cmd.always : undefined,
              message: cmd.type === "deny" ? cmd.message : undefined,
            });
            if (!ok) return fail("already_resolved", cmd.requestId);
            return;
          }
          case "revoke_grant": {
            const session = manager.get(cmd.sessionId);
            if (!session) return fail("unknown_session", cmd.sessionId);
            if (!session.revokeGrant(cmd.toolName)) return fail("unknown_grant", cmd.toolName);
            audit({ kind: "grant_revoked", sessionId: session.id, toolName: cmd.toolName, by: identity });
            return;
          }
          case "interrupt": {
            const session = manager.get(cmd.sessionId);
            if (!session) return fail("unknown_session", cmd.sessionId);
            void session.interrupt();
            return;
          }
          case "set_depth": {
            const session = manager.target(cmd.sessionId);
            if (!session) return fail("no_active_session", "create a session first");
            session.setDepth(cmd.level as 0 | 1 | 2 | 3 | 4);
            return;
          }
          case "skill": {
            const session = manager.target(cmd.sessionId);
            if (!session) return fail("no_active_session", "create a session first");
            const binding = config.skills[cmd.direction];
            if (!binding) return fail("unknown_skill", cmd.direction);
            session.prompt(binding.prompt).catch((err) => fail("turn_failed", String(err?.message ?? err)));
            return;
          }
        }
      } catch (err) {
        fail("internal", err instanceof Error ? err.message : String(err));
      }
    });

    ws.on("close", () => authed.delete(ws));
  });

  const ready = new Promise<void>((resolve) => {
    http.listen(config.port, config.bind, () => {
      const addr = http.address();
      const port = typeof addr === "object" && addr ? addr.port : config.port;
      console.log(`claude-micro server listening on ws://${config.bind}:${port}/ws`);
      console.log(`projects: ${config.projects.map((p) => p.id).join(", ") || "(none configured)"}`);
      resolve();
    });
  });

  return {
    ready,
    port: () => {
      const addr = http.address();
      return typeof addr === "object" && addr ? addr.port : config.port;
    },
    close: () =>
      new Promise<void>((resolve) => {
        for (const ws of wss.clients) ws.terminate();
        wss.close(() => http.close(() => resolve()));
      }),
  };
}
