import { createHash, randomUUID } from "crypto";
import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export interface ResolveSessionIdOptions {
  // Working directory the Claude Code session is rooted at. The session id is
  // keyed by cwd so a `--resume`/`--continue` from the same directory restores
  // the same id (and therefore re-attaches to the same Collavre topic) instead
  // of spawning a fresh orphan. pid is deliberately NOT used — it changes on
  // every restart.
  cwd: string;
  // Directory the per-cwd id files live in. Injected for testability; defaults
  // to ~/.config/collavre/sessions in production via defaultSessionStateDir().
  stateDir: string;
  // Explicit override (CLAUDE_PLUGIN_OPTION_session_id). When a non-blank value
  // is supplied the caller is pinning the session identity by hand — return it
  // verbatim and never touch the filesystem.
  override?: string;
}

export function defaultSessionStateDir(): string {
  return join(homedir(), ".config", "collavre", "sessions");
}

// Resolve a stable session id for the current working directory (S1).
//
// First use in a cwd mints a uuid and persists it under stateDir keyed by a
// hash of the absolute cwd; later calls from the same cwd read it back. This
// is what lets "stop the session, --resume later" re-bind to the same topic
// without the pid churn that previously orphaned an agent on every restart.
export function resolveSessionId(opts: ResolveSessionIdOptions): string {
  const override = opts.override?.trim();
  if (override) {
    return override;
  }

  const file = join(opts.stateDir, `${hashCwd(opts.cwd)}.id`);

  try {
    const existing = readFileSync(file, "utf-8").trim();
    if (existing) {
      return existing;
    }
  } catch {
    // Not yet created (or unreadable) — mint a fresh one below.
  }

  const id = randomUUID();
  mkdirSync(opts.stateDir, { recursive: true });
  writeFileSync(file, id, "utf-8");
  return id;
}

function hashCwd(cwd: string): string {
  return createHash("sha256").update(cwd).digest("hex").slice(0, 16);
}
