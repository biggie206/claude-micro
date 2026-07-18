// T022: protocol round-trip + permission single-resolution (US1).
import { describe, expect, it } from "vitest";
import { ClientCommand, event, PROTOCOL_VERSION, type ServerEvent } from "../src/protocol.js";
import { MicroSession, summarizeInput } from "../src/session.js";

describe("protocol round-trip", () => {
  const valid: unknown[] = [
    { v: 1, type: "hello", token: "t".repeat(32), device: "iphone", name: "Tom's iPhone" },
    { v: 1, type: "create_session", projectId: "claude-micro", depth: 3 },
    { v: 1, type: "set_active", sessionId: "s1" },
    { v: 1, type: "prompt", sessionId: "s1", text: "hi", source: "ptt" },
    { v: 1, type: "approve", sessionId: "s1", requestId: "r1", always: true },
    { v: 1, type: "deny", sessionId: "s1", requestId: "r1", message: "no" },
    { v: 1, type: "interrupt", sessionId: "s1" },
    { v: 1, type: "set_depth", level: 4 },
    { v: 1, type: "skill", direction: "up" },
    { v: 1, type: "list_projects" },
    { v: 1, type: "ping", t: 123 },
  ];

  it.each(valid.map((f) => [(f as { type: string }).type, f]))("accepts %s", (_type, frame) => {
    const parsed = ClientCommand.parse(JSON.parse(JSON.stringify(frame)));
    expect(parsed).toEqual(frame);
  });

  it("rejects unknown types, bad enums, and wrong version", () => {
    expect(() => ClientCommand.parse({ v: 1, type: "sudo" })).toThrow();
    expect(() => ClientCommand.parse({ v: 1, type: "prompt", sessionId: "s1", text: "hi", source: "telepathy" })).toThrow();
    expect(() => ClientCommand.parse({ v: 2, type: "ping", t: 1 })).toThrow();
    expect(() => ClientCommand.parse({ v: 1, type: "set_depth", level: 5 })).toThrow();
  });

  it("serializes server events losslessly", () => {
    const e: ServerEvent = {
      v: 1, type: "permission_request",
      request: { id: "r1", sessionId: "s1", toolName: "Bash", inputSummary: "Bash: rm -rf /tmp/x", risky: true, requestedAt: "2026-07-18T00:00:00Z" },
    };
    expect(JSON.parse(event(e))).toEqual(e);
    expect(PROTOCOL_VERSION).toBe(1);
  });
});

type Decision = { behavior: "allow"; updatedInput: Record<string, unknown> } | { behavior: "deny"; message: string };
/** Reach the private canUseTool bridge without a live SDK query. */
const bridge = (s: MicroSession, tool: string, input: Record<string, unknown>): Promise<Decision> =>
  (s as unknown as { bridgePermission(t: string, i: Record<string, unknown>): Promise<Decision> }).bridgePermission(tool, input);

describe("permission single-resolution (FR-004)", () => {
  it("first resolution wins; second returns false", async () => {
    const s = new MicroSession("p", "/tmp", 2);
    const emitted: string[] = [];
    s.on("permission", (r) => emitted.push(r.id));
    const decision = bridge(s, "Bash", { command: "npm test" });

    expect(emitted).toHaveLength(1);
    const requestId = emitted[0];
    expect(s.resolvePermission(requestId, "allowed", "test:one")).toBe(true);
    expect(s.resolvePermission(requestId, "allowed", "test:two")).toBe(false);
    expect(s.resolvePermission(requestId, "denied", "test:three")).toBe(false);
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: { command: "npm test" } });
  });

  it("deny carries the optional message", async () => {
    const s = new MicroSession("p", "/tmp", 2);
    let requestId = "";
    s.on("permission", (r) => { requestId = r.id; });
    const decision = bridge(s, "Bash", { command: "curl example.com" });
    expect(s.resolvePermission(requestId, "denied", "test", { message: "not now" })).toBe(true);
    await expect(decision).resolves.toEqual({ behavior: "deny", message: "not now" });
  });

  it("always-allow grants skip the gate for the same tool in-session", async () => {
    const s = new MicroSession("p", "/tmp", 2);
    let requestId = "";
    s.on("permission", (r) => { requestId = r.id; });
    const first = bridge(s, "Bash", { command: "ls" });
    s.resolvePermission(requestId, "allowed", "test", { always: true });
    await first;

    let secondEmitted = false;
    s.on("permission", () => { secondEmitted = true; });
    await expect(bridge(s, "Bash", { command: "ls -la" })).resolves.toEqual({ behavior: "allow", updatedInput: { command: "ls -la" } });
    expect(secondEmitted).toBe(false);
  });

  it("flags risky inputs and truncates summaries to 80 chars", () => {
    const s = new MicroSession("p", "/tmp", 2);
    const risky: boolean[] = [];
    s.on("permission", (r) => risky.push(r.risky));
    void bridge(s, "Bash", { command: "rm -rf /tmp/scratch" });
    void bridge(s, "Bash", { command: "git push --force origin main" });
    void bridge(s, "Bash", { command: "ls" });
    expect(risky).toEqual([true, true, false]);
    const summary = summarizeInput("Bash", { command: "x".repeat(200) });
    expect(summary.length).toBeLessThanOrEqual(80);
    expect(summary.endsWith("…")).toBe(true);
  });

  it("auto-denies after the configured timeout (FR-003)", async () => {
    const s = new MicroSession("p", "/tmp", 2, 30);
    const resolved: string[] = [];
    s.on("permissionResolved", (_id, resolution, by) => resolved.push(`${resolution}:${by}`));
    await expect(bridge(s, "Bash", { command: "sleep 999" })).resolves.toEqual({
      behavior: "deny", message: "permission request timed out",
    });
    expect(resolved).toEqual(["denied:system:timeout"]);
  });
});
