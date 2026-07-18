// FR-021 / T046: discover resumable SDK sessions from on-disk transcripts.
// Claude Code stores transcripts at ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl;
// the directory name encodes the cwd with every '/' and '.' replaced by '-'.
import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function encodeCwd(cwd: string): string {
  return cwd.replace(/[/.]/g, "-");
}

export interface ResumableSession {
  sessionId: string;
  mtimeMs: number;
}

/** Most-recent-first resumable session ids for a project cwd, capped. */
export function discoverResumable(cwd: string, limit = 3, projectsRoot = join(homedir(), ".claude", "projects")): ResumableSession[] {
  const dir = join(projectsRoot, encodeCwd(cwd));
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return []; // project never used with Claude Code — nothing to resume
  }
  const sessions: ResumableSession[] = [];
  for (const name of entries) {
    if (!name.endsWith(".jsonl")) continue;
    const sessionId = name.slice(0, -".jsonl".length);
    if (!UUID_RE.test(sessionId)) continue;
    try {
      sessions.push({ sessionId, mtimeMs: statSync(join(dir, name)).mtimeMs });
    } catch {
      // raced deletion — skip
    }
  }
  return sessions.sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, limit);
}
