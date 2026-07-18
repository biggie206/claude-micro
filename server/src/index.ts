// Claude Micro companion server — WebSocket API over the Agent SDK.
// Run on the Mac that has Claude Code authenticated. See specs/001-claude-micro/quickstart.md
import { timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import { ClientCommand, event, PROTOCOL_VERSION, type ServerEvent } from "./protocol.js";
import { SessionManager } from "./session-manager.js";
import type { MicroSession } from "./session.js";

interface Config {
  token: string;
  bind: string;
  port: number;
  defaultDepth: 0 | 1 | 2 | 3 | 4;
  permissionTimeoutMs?: number | null;
  projects: { id: string; name: string; cwd: string }[];
  skills: Record<"up" | "down" | "left" | "right", { label: string; prompt: string }>;
}

const configPath = process.env.CLAUDE_MICRO_CONFIG ?? new URL("../claude-micro.config.json", import.meta.url).pathname;
const config: Config = JSON.parse(readFileSync(configPath, "utf8"));
if (!config.token || config.token.length < 16) {
  console.error("Refusing to start: config token missing or too short (Constitution V).");
  process.exit(1);
}

const manager = new SessionManager(config.projects, config.defaultDepth, config.permissionTimeoutMs ?? null);
const authed = new Map<WebSocket, { device: string; name: string }>();

const broadcast = (e: ServerEvent) => {
  const frame = event(e);
  for (const ws of authed.keys()) if (ws.readyState === WebSocket.OPEN) ws.send(frame);
};

function wireSession(session: MicroSession): void {
  session.on("state", () => broadcast({ v: 1, type: "session_state", session: session.toShape() }));
  session.on("delta", (text) => broadcast({ v: 1, type: "assistant_delta", sessionId: session.id, text }));
  session.on("tool", (toolName, summary) => broadcast({ v: 1, type: "tool_activity", sessionId: session.id, toolName, summary }));
  session.on("permission", (request) => broadcast({ v: 1, type: "permission_request", request }));
  session.on("permissionResolved", (requestId, resolution, by) => broadcast({ v: 1, type: "permission_resolved", requestId, resolution, by }));
  session.on("result", (subtype, costUSD, durationMs, summary) =>
    broadcast({ v: 1, type: "turn_result", sessionId: session.id, subtype, costUSD, durationMs, summary }));
}

/** Constant-time compare so the shared token can't be brute-forced via timing. */
const tokenMatches = (candidate: string): boolean => {
  const a = Buffer.from(candidate);
  const b = Buffer.from(config.token);
  return a.length === b.length && timingSafeEqual(a, b);
};

const http = createServer((_req, res) => { res.writeHead(200); res.end("claude-micro ok\n"); });
// maxPayload: unauthenticated peers must not be able to buffer huge frames (default is 100 MiB).
const wss = new WebSocketServer({ server: http, path: "/ws", maxPayload: 1024 * 1024 });
wss.on("error", (err) => console.error("wss error:", err.message));

wss.on("connection", (ws) => {
  const fail = (code: string, message: string) => ws.send(event({ v: 1, type: "error", code, message }));
  ws.on("error", () => ws.close()); // a socket error must never crash the server

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
      if (!tokenMatches(cmd.token)) return ws.close(4401, "bad token");
      authed.set(ws, { device: cmd.device, name: cmd.name });
      return ws.send(event({ v: 1, type: "snapshot", ...manager.snapshot() }));
    }

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
          const ok = session.resolvePermission(cmd.requestId, resolution, `${client.device}:${client.name}`, {
            always: cmd.type === "approve" ? cmd.always : undefined,
            message: cmd.type === "deny" ? cmd.message : undefined,
          });
          if (!ok) return fail("already_resolved", cmd.requestId);
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

http.listen(config.port, config.bind, () => {
  console.log(`claude-micro server listening on ws://${config.bind}:${config.port}/ws`);
  console.log(`projects: ${config.projects.map((p) => p.id).join(", ") || "(none configured)"}`);
});
