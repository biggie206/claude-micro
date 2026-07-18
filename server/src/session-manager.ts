// Session registry + active-session routing + snapshot builder (Constitution II).
import { MicroSession } from "./session.js";
import type { PendingPermissionShape, ProjectShape, SessionShape, DepthLevel } from "./protocol.js";

export class SessionManager {
  private sessions = new Map<string, MicroSession>();
  private activeId: string | null = null;

  constructor(
    readonly projects: ProjectShape[],
    private defaultDepth: DepthLevel,
    private permissionTimeoutMs: number | null = null,
  ) {}

  create(projectId: string, depth?: DepthLevel): MicroSession {
    const project = this.projects.find((p) => p.id === projectId);
    if (!project) throw new Error(`unknown_project:${projectId}`);
    const session = new MicroSession(project.id, project.cwd, depth ?? this.defaultDepth, this.permissionTimeoutMs);
    this.sessions.set(session.id, session);
    // MicroSession.id mutates from placeholder → SDK id on first init; re-key lazily in get().
    this.setActive(session.id);
    return session;
  }

  get(sessionId: string): MicroSession | undefined {
    const direct = this.sessions.get(sessionId);
    if (direct) return direct;
    // Re-key sessions whose id changed after SDK init.
    for (const [key, s] of this.sessions) {
      if (s.id !== key) {
        this.sessions.delete(key);
        this.sessions.set(s.id, s);
        if (this.activeId === key) this.activeId = s.id;
      }
    }
    return this.sessions.get(sessionId);
  }

  /** Resolve explicit id or fall back to the active session. */
  target(sessionId?: string): MicroSession | undefined {
    if (sessionId) return this.get(sessionId);
    return this.activeId ? this.get(this.activeId) : undefined;
  }

  setActive(sessionId: string): boolean {
    const s = this.get(sessionId);
    if (!s) return false;
    for (const other of this.sessions.values()) other.active = false;
    s.active = true;
    this.activeId = s.id;
    return true;
  }

  all(): MicroSession[] {
    // touch get() to re-key any renamed sessions before listing
    this.get("__rekey__");
    return [...this.sessions.values()];
  }

  snapshot(): { sessions: SessionShape[]; pending: PendingPermissionShape[]; projects: ProjectShape[]; activeSessionId: string | null } {
    const sessions = this.all();
    return {
      sessions: sessions.map((s) => s.toShape()),
      pending: sessions.flatMap((s) => s.pendingRequests()),
      projects: this.projects,
      activeSessionId: this.activeId,
    };
  }
}
