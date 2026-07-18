// T050: WS integration tests over a real server — auth (SC-006) + FR-017/FR-018 hardening.
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { startServer, upgradeAllowed, validateConfig, type Config } from "../src/server.js";

const TOKEN = "t".repeat(32);
const auditDir = mkdtempSync(join(tmpdir(), "claude-micro-test-"));

const baseConfig = (): Config => ({
  tokens: [{ id: "phone", token: TOKEN }],
  bind: "127.0.0.1",
  port: 0,
  defaultDepth: 2,
  auditLog: join(auditDir, `audit-${Math.random().toString(36).slice(2)}.jsonl`),
  handshakeTimeoutMs: 150,
  projects: [{ id: "p1", name: "Project One", cwd: tmpdir() }],
  skills: {
    up: { label: "U", prompt: "u" }, down: { label: "D", prompt: "d" },
    left: { label: "L", prompt: "l" }, right: { label: "R", prompt: "r" },
  },
});

let server: ReturnType<typeof startServer> | null = null;
afterEach(async () => { await server?.close(); server = null; });

const boot = async (config: Config) => {
  server = startServer(config);
  await server.ready;
  return server;
};

const url = () => `ws://127.0.0.1:${server!.port()}/ws`;

const waitClose = (ws: WebSocket) =>
  new Promise<{ code: number; reason: string }>((resolve) =>
    ws.on("close", (code, reason) => resolve({ code, reason: String(reason) })));

const nextMessage = (ws: WebSocket) =>
  new Promise<any>((resolve) => ws.once("message", (raw) => resolve(JSON.parse(String(raw)))));

const opened = (ws: WebSocket) => new Promise<void>((resolve) => ws.on("open", () => resolve()));

const hello = (ws: WebSocket, token = TOKEN) =>
  ws.send(JSON.stringify({ v: 1, type: "hello", token, device: "other", name: "test" }));

describe("auth (SC-006, FR-017)", () => {
  it("rejects wrong token with 4401 and backs off the source address with 4429", async () => {
    await boot(baseConfig());
    const ws1 = new WebSocket(url());
    await opened(ws1);
    hello(ws1, "wrong-token-wrong-token");
    expect(await waitClose(ws1)).toMatchObject({ code: 4401, reason: "bad token" });

    const ws2 = new WebSocket(url()); // blocked by backoff before any frame
    await opened(ws2);
    expect((await waitClose(ws2)).code).toBe(4429);
  });

  it("rejects non-hello first frames", async () => {
    await boot(baseConfig());
    const ws = new WebSocket(url());
    await opened(ws);
    ws.send(JSON.stringify({ v: 1, type: "ping", t: 1 }));
    expect((await waitClose(ws)).code).toBe(4401);
  });

  it("accepts a named token, replies snapshot, and audits auth events", async () => {
    const config = baseConfig();
    await boot(config);
    const ws = new WebSocket(url());
    await opened(ws);
    hello(ws);
    const snap = await nextMessage(ws);
    expect(snap.type).toBe("snapshot");
    expect(snap.projects).toHaveLength(1);
    ws.close();
    await waitClose(ws);
    await new Promise((r) => setTimeout(r, 50)); // audit append is async
    const lines = readFileSync(config.auditLog as string, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    expect(lines.some((l) => l.kind === "auth_ok" && l.tokenId === "phone")).toBe(true);
  });

  it("validateConfig rejects missing/short/duplicate tokens", () => {
    expect(validateConfig({ ...baseConfig(), tokens: [] })).toMatch(/no token/);
    expect(validateConfig({ ...baseConfig(), tokens: [{ id: "a", token: "short" }] })).toMatch(/too short/);
    expect(validateConfig({ ...baseConfig(), tokens: [{ id: "a", token: TOKEN }, { id: "a", token: TOKEN }] })).toMatch(/duplicate/);
  });
});

describe("connection hardening (FR-018)", () => {
  it("closes sockets that never authenticate (handshake timeout)", async () => {
    await boot(baseConfig());
    const ws = new WebSocket(url());
    await opened(ws);
    const { code, reason } = await waitClose(ws);
    expect(code).toBe(4401);
    expect(reason).toBe("auth timeout");
  });

  it("caps concurrent unauthenticated sockets", async () => {
    await boot({ ...baseConfig(), maxUnauthedSockets: 2, handshakeTimeoutMs: 5000 });
    const a = new WebSocket(url());
    const b = new WebSocket(url());
    await Promise.all([opened(a), opened(b)]);
    const c = new WebSocket(url());
    await opened(c);
    expect((await waitClose(c)).reason).toBe("too many pending connections");
    a.terminate(); b.terminate();
  });

  it("rejects upgrades carrying a browser Origin header", async () => {
    await boot(baseConfig());
    const ws = new WebSocket(url(), { headers: { Origin: "https://evil.example.com" } });
    await opened(ws);
    expect((await waitClose(ws)).code).toBe(4403);
  });

  it("rejects non-allowlisted Host names but allows IPs, localhost, and allowlisted names", async () => {
    await boot({ ...baseConfig(), allowedHosts: ["mac.tail1234.ts.net"] });
    const bad = new WebSocket(url(), { headers: { Host: "evil.example.com" } });
    await opened(bad);
    expect((await waitClose(bad)).code).toBe(4403);

    const good = new WebSocket(url(), { headers: { Host: "mac.tail1234.ts.net" } });
    await opened(good);
    hello(good);
    expect((await nextMessage(good)).type).toBe("snapshot");
    good.close();
  });

  it("upgradeAllowed unit: origin always rejected; host classes", () => {
    const req = (headers: Record<string, string>) => ({ headers }) as any;
    expect(upgradeAllowed(req({ host: "127.0.0.1:8787" }), [])).toBe(true);
    expect(upgradeAllowed(req({ host: "localhost:8787" }), [])).toBe(true);
    expect(upgradeAllowed(req({ host: "[::1]:8787" }), [])).toBe(true);
    expect(upgradeAllowed(req({ host: "rebind.attacker.io:8787" }), [])).toBe(false);
    expect(upgradeAllowed(req({ host: "127.0.0.1:8787", origin: "http://x" }), [])).toBe(false);
    expect(upgradeAllowed(req({}), [])).toBe(false);
  });
});

describe("grants over the wire (FR-016)", () => {
  it("snapshot sessions carry grants; revoke_grant errors on unknown grant/session", async () => {
    await boot(baseConfig());
    const ws = new WebSocket(url());
    await opened(ws);
    hello(ws);
    await nextMessage(ws); // initial snapshot
    ws.send(JSON.stringify({ v: 1, type: "create_session", projectId: "p1" }));
    const snap = await nextMessage(ws);
    expect(snap.type).toBe("snapshot");
    expect(snap.sessions[0].grants).toEqual([]);
    const sessionId = snap.sessions[0].id;

    ws.send(JSON.stringify({ v: 1, type: "revoke_grant", sessionId, toolName: "Bash" }));
    expect(await nextMessage(ws)).toMatchObject({ type: "error", code: "unknown_grant" });

    ws.send(JSON.stringify({ v: 1, type: "revoke_grant", sessionId: "nope", toolName: "Bash" }));
    expect(await nextMessage(ws)).toMatchObject({ type: "error", code: "unknown_session" });
    ws.close();
  });
});
