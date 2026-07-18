// Claude Micro WebSocket protocol v1 — normative schemas.
// Mirrored by specs/001-claude-micro/contracts/websocket-protocol.md and apple/Shared/Models.swift
import { z } from "zod";

export const PROTOCOL_VERSION = 1;

// ---------- shared shapes ----------

export const SessionStatus = z.enum([
  "idle", "thinking", "working", "needs_input", "complete", "error", "interrupted",
]);
export type SessionStatus = z.infer<typeof SessionStatus>;

export const DepthLevel = z.number().int().min(0).max(4);
export type DepthLevel = z.infer<typeof DepthLevel>;

export const SessionShape = z.object({
  id: z.string(),
  projectId: z.string(),
  cwd: z.string(),
  status: SessionStatus,
  depth: DepthLevel,
  active: z.boolean(),
  lastSnippet: z.string(),
  costUSD: z.number(),
  startedAt: z.string(),
  lastActivityAt: z.string(),
});
export type SessionShape = z.infer<typeof SessionShape>;

export const PendingPermissionShape = z.object({
  id: z.string(),
  sessionId: z.string(),
  toolName: z.string(),
  inputSummary: z.string(),
  risky: z.boolean(),
  requestedAt: z.string(),
});
export type PendingPermissionShape = z.infer<typeof PendingPermissionShape>;

export const ProjectShape = z.object({ id: z.string(), name: z.string(), cwd: z.string() });
export type ProjectShape = z.infer<typeof ProjectShape>;

// ---------- client → server commands ----------

const base = { v: z.literal(PROTOCOL_VERSION) };

export const ClientCommand = z.discriminatedUnion("type", [
  z.object({ ...base, type: z.literal("hello"), token: z.string(), device: z.enum(["iphone", "watch", "other"]), name: z.string() }),
  z.object({ ...base, type: z.literal("create_session"), projectId: z.string(), depth: DepthLevel.optional() }),
  z.object({ ...base, type: z.literal("set_active"), sessionId: z.string() }),
  z.object({ ...base, type: z.literal("prompt"), sessionId: z.string(), text: z.string(), source: z.enum(["ptt", "typed", "skill"]) }),
  z.object({ ...base, type: z.literal("approve"), sessionId: z.string(), requestId: z.string(), always: z.boolean().optional() }),
  z.object({ ...base, type: z.literal("deny"), sessionId: z.string(), requestId: z.string(), message: z.string().optional() }),
  z.object({ ...base, type: z.literal("interrupt"), sessionId: z.string() }),
  z.object({ ...base, type: z.literal("set_depth"), sessionId: z.string().optional(), level: DepthLevel }),
  z.object({ ...base, type: z.literal("skill"), sessionId: z.string().optional(), direction: z.enum(["up", "down", "left", "right"]) }),
  z.object({ ...base, type: z.literal("list_projects") }),
  z.object({ ...base, type: z.literal("ping"), t: z.number() }),
]);
export type ClientCommand = z.infer<typeof ClientCommand>;

// ---------- server → client events ----------

export type ServerEvent =
  | { v: 1; type: "snapshot"; sessions: SessionShape[]; pending: PendingPermissionShape[]; projects: ProjectShape[]; activeSessionId: string | null }
  | { v: 1; type: "session_state"; session: SessionShape }
  | { v: 1; type: "assistant_delta"; sessionId: string; text: string }
  | { v: 1; type: "tool_activity"; sessionId: string; toolName: string; summary: string }
  | { v: 1; type: "permission_request"; request: PendingPermissionShape }
  | { v: 1; type: "permission_resolved"; requestId: string; resolution: "allowed" | "denied"; by: string }
  | { v: 1; type: "turn_result"; sessionId: string; subtype: string; costUSD: number; durationMs: number; summary: string }
  | { v: 1; type: "error"; code: string; message: string; sessionId?: string }
  | { v: 1; type: "pong"; t: number };

export const event = <T extends ServerEvent>(e: T): string => JSON.stringify(e);
