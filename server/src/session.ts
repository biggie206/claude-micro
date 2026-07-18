// MicroSession: wraps one Claude Code session driven turn-by-turn via the Agent SDK.
// Design (plan.md): one query() per user turn with `resume`, so the thinking-depth dial
// can apply per-turn; canUseTool bridges SDK permission gates to phone/watch clients.
import { query, type Query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { thinkingForDepth } from "./depth.js";
import type { DepthLevel, PendingPermissionShape, SessionShape, SessionStatus } from "./protocol.js";

const RISKY_PATTERNS = [/\brm\s+-rf?\b/i, /--force\b/, /\bsudo\b/, /force-push|push\s+--force/i, /\bdd\b/, /\bmkfs\b/, /DROP\s+TABLE/i];

interface PendingInternal extends PendingPermissionShape {
  resolve: (r: { behavior: "allow"; updatedInput: Record<string, unknown> } | { behavior: "deny"; message: string }) => void;
  input: Record<string, unknown>;
  timer?: NodeJS.Timeout;
}

/** Internal audit detail attached to permissionResolved (FR-015); not sent on the wire. */
export interface ResolutionAudit {
  toolName: string;
  input: Record<string, unknown>;
  inputSummary: string;
  risky: boolean;
  always: boolean;
}

export interface MicroSessionEvents {
  state: [];
  delta: [text: string];
  tool: [toolName: string, summary: string];
  permission: [request: PendingPermissionShape];
  permissionResolved: [requestId: string, resolution: "allowed" | "denied", by: string, audit: ResolutionAudit];
  result: [subtype: string, costUSD: number, durationMs: number, summary: string];
}

export class MicroSession extends EventEmitter<MicroSessionEvents> {
  /** SDK session id once known; placeholder id before the first init message. */
  id: string;
  readonly projectId: string;
  readonly cwd: string;
  status: SessionStatus = "idle";
  depth: DepthLevel;
  active = false;
  lastSnippet = "";
  costUSD = 0;
  readonly startedAt = new Date().toISOString();
  lastActivityAt = new Date().toISOString();

  private sdkSessionId: string | null = null;
  private currentQuery: Query | null = null;
  private pending = new Map<string, PendingInternal>();
  private alwaysAllow = new Set<string>(); // toolName grants, session-scoped only

  constructor(projectId: string, cwd: string, depth: DepthLevel, private permissionTimeoutMs: number | null = null) {
    super();
    this.id = `pending-${randomUUID()}`;
    this.projectId = projectId;
    this.cwd = cwd;
    this.depth = depth;
  }

  /** FR-021: rebuild a session around an on-disk SDK transcript — idle until the next
   *  prompt, which resumes with full context. Marked "(resumable)" per spec Edge Cases. */
  static resumed(projectId: string, cwd: string, depth: DepthLevel, sdkSessionId: string, permissionTimeoutMs: number | null = null): MicroSession {
    const s = new MicroSession(projectId, cwd, depth, permissionTimeoutMs);
    s.id = sdkSessionId;
    s.sdkSessionId = sdkSessionId;
    s.lastSnippet = "(resumable)";
    return s;
  }

  toShape(): SessionShape {
    return {
      id: this.id, projectId: this.projectId, cwd: this.cwd, status: this.status,
      depth: this.depth, active: this.active, grants: [...this.alwaysAllow].sort(),
      lastSnippet: this.lastSnippet,
      costUSD: this.costUSD, startedAt: this.startedAt, lastActivityAt: this.lastActivityAt,
    };
  }

  /** FR-016: revoke a standing always-allow grant. */
  revokeGrant(toolName: string): boolean {
    const removed = this.alwaysAllow.delete(toolName);
    if (removed) this.touch("state");
    return removed;
  }

  pendingRequests(): PendingPermissionShape[] {
    return [...this.pending.values()].map(({ resolve: _r, input: _i, timer: _t, ...shape }) => shape);
  }

  setDepth(level: DepthLevel): void {
    this.depth = level; // applied on next turn via thinkingForDepth
    this.touch("state");
  }

  /** Run one user turn. Serialized: rejects if a turn is already running. */
  async prompt(text: string): Promise<void> {
    if (this.currentQuery) throw new Error("turn_in_progress");
    this.setStatus("thinking");
    const started = Date.now();

    const q = query({
      prompt: text,
      options: {
        cwd: this.cwd,
        ...(this.sdkSessionId ? { resume: this.sdkSessionId } : {}),
        thinking: thinkingForDepth(this.depth),
        includePartialMessages: true,
        settingSources: ["project"],
        canUseTool: (toolName: string, input: Record<string, unknown>) =>
          this.bridgePermission(toolName, input),
      } as Parameters<typeof query>[0]["options"],
    });
    this.currentQuery = q;

    try {
      for await (const message of q as AsyncIterable<SDKMessage>) {
        this.handleMessage(message, started);
      }
    } catch (err) {
      this.setStatus("error");
      this.lastSnippet = err instanceof Error ? err.message.slice(0, 120) : "unknown error";
      this.emit("result", "error_during_execution", this.costUSD, Date.now() - started, this.lastSnippet);
    } finally {
      this.currentQuery = null;
      this.rejectAllPending("session turn ended");
      if (this.status === "thinking" || this.status === "working" || this.status === "needs_input") {
        this.setStatus("idle");
      }
    }
  }

  async interrupt(): Promise<void> {
    if (!this.currentQuery) return;
    await this.currentQuery.interrupt();
    this.rejectAllPending("interrupted by user");
    this.setStatus("interrupted");
  }

  resolvePermission(requestId: string, resolution: "allowed" | "denied", by: string, opts?: { always?: boolean; message?: string }): boolean {
    const p = this.pending.get(requestId);
    if (!p) return false; // already resolved or unknown
    this.pending.delete(requestId);
    if (p.timer) clearTimeout(p.timer);
    // FR-016 / Constitution V: a risky invocation can never mint a standing grant.
    const always = Boolean(opts?.always) && !p.risky;
    if (resolution === "allowed") {
      if (always) this.alwaysAllow.add(p.toolName);
      p.resolve({ behavior: "allow", updatedInput: p.input });
    } else {
      p.resolve({ behavior: "deny", message: opts?.message ?? "Denied from Claude Micro" });
    }
    this.emit("permissionResolved", requestId, resolution, by,
      { toolName: p.toolName, input: p.input, inputSummary: p.inputSummary, risky: p.risky, always });
    if (this.pending.size === 0 && this.status === "needs_input") this.setStatus("working");
    if (always) this.touch("state"); // grants changed → clients see it in session state
    return true;
  }

  // ---------- internals ----------

  private bridgePermission(toolName: string, input: Record<string, unknown>) {
    const inputStr = JSON.stringify(input);
    const risky = RISKY_PATTERNS.some((re) => re.test(inputStr));
    // FR-016 / Constitution V: standing grants never satisfy a RISKY invocation —
    // "always allow Bash" must not silently green-light a later `rm -rf`.
    if (!risky && this.alwaysAllow.has(toolName)) {
      return Promise.resolve({ behavior: "allow" as const, updatedInput: input });
    }
    const request: PendingInternal = {
      id: randomUUID(),
      sessionId: this.id,
      toolName,
      inputSummary: summarizeInput(toolName, input),
      risky,
      requestedAt: new Date().toISOString(),
      input,
      resolve: () => {},
    };
    const promise = new Promise<{ behavior: "allow"; updatedInput: Record<string, unknown> } | { behavior: "deny"; message: string }>(
      (resolve) => { request.resolve = resolve; },
    );
    this.pending.set(request.id, request);
    this.setStatus("needs_input");
    const { resolve: _r, input: _i, timer: _t, ...shape } = request;
    this.emit("permission", shape);
    if (this.permissionTimeoutMs && this.permissionTimeoutMs > 0) {
      // FR-003: configurable timeout (default none) auto-denies unresolved requests.
      request.timer = setTimeout(() => {
        this.resolvePermission(request.id, "denied", "system:timeout", { message: "permission request timed out" });
      }, this.permissionTimeoutMs);
      request.timer.unref?.();
    }
    return promise;
  }

  private handleMessage(message: SDKMessage, turnStarted: number): void {
    const m = message as Record<string, any>;
    switch (m.type) {
      case "system":
        if (m.subtype === "init" && typeof m.session_id === "string") {
          this.sdkSessionId = m.session_id;
          if (this.id.startsWith("pending-")) this.id = m.session_id;
        }
        break;
      case "stream_event": {
        const delta = m.event?.delta;
        if (m.event?.type === "content_block_delta" && delta?.type === "text_delta" && delta.text) {
          if (this.status === "thinking") this.setStatus("working");
          this.lastSnippet = (this.lastSnippet + delta.text).slice(-120);
          this.touch();
          this.emit("delta", delta.text);
        }
        break;
      }
      case "assistant": {
        const blocks: any[] = m.message?.content ?? [];
        for (const block of blocks) {
          if (block.type === "tool_use") {
            if (this.status === "thinking") this.setStatus("working");
            this.emit("tool", block.name, summarizeInput(block.name, block.input ?? {}));
          }
        }
        break;
      }
      case "result": {
        this.costUSD += typeof m.total_cost_usd === "number" ? m.total_cost_usd : 0;
        const ok = m.subtype === "success";
        this.setStatus(ok ? "complete" : "error");
        const summary = (typeof m.result === "string" ? m.result : this.lastSnippet).slice(0, 200);
        this.emit("result", m.subtype ?? "unknown", this.costUSD, Date.now() - turnStarted, summary);
        break;
      }
    }
  }

  private rejectAllPending(reason: string): void {
    for (const [id, p] of this.pending) {
      if (p.timer) clearTimeout(p.timer);
      p.resolve({ behavior: "deny", message: reason });
      this.pending.delete(id);
      this.emit("permissionResolved", id, "denied", "system",
        { toolName: p.toolName, input: p.input, inputSummary: p.inputSummary, risky: p.risky, always: false });
    }
  }

  private setStatus(s: SessionStatus): void {
    if (this.status !== s) { this.status = s; this.touch("state"); } else this.touch();
  }

  private touch(emitState?: "state"): void {
    this.lastActivityAt = new Date().toISOString();
    if (emitState) this.emit("state");
  }
}

/** One-line, ≤80-char summary for glanceable clients (Constitution I). */
export function summarizeInput(toolName: string, input: Record<string, unknown>): string {
  const pick =
    (input.command as string) ?? (input.file_path as string) ?? (input.path as string) ??
    (input.pattern as string) ?? (input.url as string) ?? (input.description as string) ??
    JSON.stringify(input);
  const s = `${toolName}: ${String(pick)}`.replace(/\s+/g, " ").trim();
  return s.length > 80 ? s.slice(0, 77) + "…" : s;
}
