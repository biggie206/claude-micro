// T046/T056 (FR-021): restart recovery, heartbeat culling, graceful shutdown.
import { mkdtempSync, mkdirSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { discoverResumable, encodeCwd } from "../src/resume.js";
import { startServer, type Config } from "../src/server.js";
import { MicroSession } from "../src/session.js";
import { SessionManager } from "../src/session-manager.js";

const TOKEN = "t".repeat(32);
const UUID_A = "aaaaaaaa-1111-2222-3333-444444444444";
const UUID_B = "bbbbbbbb-1111-2222-3333-444444444444";

const config = (over: Partial<Config> = {}): Config => ({
  tokens: [{ id: "phone", token: TOKEN }],
  bind: "127.0.0.1",
  port: 0,
  defaultDepth: 2,
  auditLog: false,
  resumeSessions: false,
  projects: [{ id: "p1", name: "One", cwd: "/tmp/p1" }],
  skills: {
    up: { label: "U", prompt: "u" }, down: { label: "D", prompt: "d" },
    left: { label: "L", prompt: "l" }, right: { label: "R", prompt: "r" },
  },
  ...over,
});

let server: ReturnType<typeof startServer> | null = null;
afterEach(async () => { await server?.close(); server = null; });

const opened = (ws: WebSocket) => new Promise<void>((r) => ws.on("open", () => r()));
const waitClose = (ws: WebSocket) =>
  new Promise<{ code: number; reason: string }>((r) => ws.on("close", (code, reason) => r({ code, reason: String(reason) })));
const nextMessage = (ws: WebSocket) => new Promise<any>((r) => ws.once("message", (raw) => r(JSON.parse(String(raw)))));

describe("restart recovery (T046, FR-021)", () => {
  it("encodeCwd matches the SDK's on-disk project naming", () => {
    expect(encodeCwd("/Users/tomnguyen/Developer/claude-micro")).toBe("-Users-tomnguyen-Developer-claude-micro");
    expect(encodeCwd("/tmp/x.y/z")).toBe("-tmp-x-y-z");
  });

  it("discoverResumable finds uuid transcripts newest-first, capped, ignoring junk", () => {
    const root = mkdtempSync(join(tmpdir(), "cm-resume-"));
    const cwd = "/tmp/proj";
    const dir = join(root, encodeCwd(cwd));
    mkdirSync(dir, { recursive: true });
    const old = join(dir, `${UUID_A}.jsonl`);
    const fresh = join(dir, `${UUID_B}.jsonl`);
    writeFileSync(old, "{}\n");
    writeFileSync(fresh, "{}\n");
    utimesSync(old, new Date(Date.now() - 60_000), new Date(Date.now() - 60_000));
    writeFileSync(join(dir, "notes.txt"), "junk");
    writeFileSync(join(dir, "not-a-uuid.jsonl"), "junk");

    const found = discoverResumable(cwd, 3, root);
    expect(found.map((f) => f.sessionId)).toEqual([UUID_B, UUID_A]);
    expect(discoverResumable(cwd, 1, root)).toHaveLength(1);
    expect(discoverResumable("/never/used", 3, root)).toEqual([]);
  });

  it("restored sessions are idle, resumable-labeled, and prompt with resume id", () => {
    const s = MicroSession.resumed("p1", "/tmp/p1", 2, UUID_A);
    const shape = s.toShape();
    expect(shape.id).toBe(UUID_A);
    expect(shape.status).toBe("idle");
    expect(shape.lastSnippet).toBe("(resumable)");
    expect(shape.grants).toEqual([]);
    expect((s as unknown as { sdkSessionId: string | null }).sdkSessionId).toBe(UUID_A);
  });

  it("SessionManager.restore registers without activating and dedupes", () => {
    const m = new SessionManager([{ id: "p1", name: "One", cwd: "/tmp/p1" }], 2);
    const s = m.restore("p1", UUID_A);
    expect(s).not.toBeNull();
    expect(m.activeSessionId).toBeNull();
    expect(m.restore("p1", UUID_A)).toBeNull();          // dedupe
    expect(m.restore("nope", UUID_B)).toBeNull();        // unknown project
    expect(m.snapshot().sessions).toHaveLength(1);
  });
});

describe("liveness + shutdown (T056, FR-021)", () => {
  it("terminates peers that miss a pong; responsive peers survive", async () => {
    server = startServer(config({ heartbeatMs: 60, handshakeTimeoutMs: 5000 }));
    await server.ready;
    const url = `ws://127.0.0.1:${server.port()}/ws`;

    const zombie = new WebSocket(url, { autoPong: false });
    const healthy = new WebSocket(url);
    await Promise.all([opened(zombie), opened(healthy)]);

    const closed = await Promise.race([
      waitClose(zombie).then(() => "zombie-culled"),
      new Promise((r) => setTimeout(() => r("timeout"), 1000)),
    ]);
    expect(closed).toBe("zombie-culled");
    expect(healthy.readyState).toBe(WebSocket.OPEN);
    healthy.terminate();
  });

  it("shutdown notifies authed clients and closes with 1001", async () => {
    server = startServer(config());
    await server.ready;
    const ws = new WebSocket(`ws://127.0.0.1:${server.port()}/ws`);
    await opened(ws);
    ws.send(JSON.stringify({ v: 1, type: "hello", token: TOKEN, device: "other", name: "t" }));
    await nextMessage(ws); // snapshot

    const notice = nextMessage(ws);
    const closeInfo = waitClose(ws);
    await server.shutdown();
    server = null; // already closed
    expect(await notice).toMatchObject({ type: "error", code: "shutting_down" });
    expect((await closeInfo).code).toBe(1001);
  });
});
