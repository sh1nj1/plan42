import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

export interface QuotaTurn { task_id: number; execution_generation: string }
export function quotaDirectory(cwd: string, root = join(homedir(), ".config", "collavre", "sessions")): string {
  return join(root, `quota-${createHash("sha256").update(cwd).digest("hex")}`);
}

// Per-process state avoids overwriting sibling sessions in the same cwd.
export class QuotaState {
  private turns = new Map<number, QuotaTurn>();
  private directory: string;
  private pid: number;
  private persistenceFailed = false;
  constructor(directory: string, pid = process.pid) { this.directory = directory; this.pid = pid; this.save(); }
  add(turn: QuotaTurn): void { if (this.persistenceFailed) return; this.turns.set(turn.task_id, turn); this.save(); }
  remove(taskId: number, generation?: string): void {
    if (generation && this.turns.get(taskId)?.execution_generation !== generation) return;
    this.turns.delete(taskId); this.save();
  }
  async prune(isCurrent: (turn: QuotaTurn) => Promise<boolean>): Promise<void> {
    await Promise.all([...this.turns.values()].map(async turn => {
      try { if (!await isCurrent(turn)) this.remove(turn.task_id, turn.execution_generation); } catch { /* Keep uncertain turns. */ }
    }));
  }
  clear(): void {
    this.turns.clear();
    try { rmSync(join(this.directory, `${this.pid}.json`), { force: true }); } catch { /* Best effort on read-only filesystems. */ }
  }
  private save(): void {
    if (this.persistenceFailed) return;
    try {
      mkdirSync(this.directory, { recursive: true, mode: 0o700 });
      const target = join(this.directory, `${this.pid}.json`);
      writeFileSync(`${target}.tmp`, JSON.stringify([...this.turns.values()]), { mode: 0o600 });
      renameSync(`${target}.tmp`, target);
    } catch {
      this.persistenceFailed = true;
      this.clear();
      process.stderr.write("[collavre] Quota recovery state is unavailable; continuing without local quota tracking\n");
    }
  }
}

export function quotaTurns(directory: string, alive = (pid: number) => { process.kill(pid, 0); }): QuotaTurn[] | null {
  const turns: QuotaTurn[] = [];
  let liveSessions = 0;
  try {
    for (const file of readdirSync(directory)) {
      if (!/^\d+\.json$/.test(file)) continue;
      try { alive(Number(file.split(".")[0])); } catch { continue; }
      if (++liveSessions > 1) return null;
      const values = JSON.parse(readFileSync(join(directory, file), "utf8")) as QuotaTurn[];
      if (!Array.isArray(values)) return null;
      turns.push(...values);
    }
  } catch { return null; }
  return turns.every(turn => turn != null && Number.isSafeInteger(turn.task_id) && turn.task_id > 0 &&
    typeof turn.execution_generation === "string" && turn.execution_generation.length > 0) ? turns : null;
}

export function onlyQuotaTurn(directory: string, alive?: (pid: number) => void): QuotaTurn | null {
  const turns = quotaTurns(directory, alive);
  return turns?.length === 1 ? turns[0] : null;
}

export async function currentQuotaTurn(directory: string, isCurrent: (turn: QuotaTurn) => Promise<boolean>): Promise<QuotaTurn | null> {
  const turns = quotaTurns(directory);
  if (!turns) return null;
  // A failed lookup leaves attribution uncertain; never guess which turn failed.
  try {
    const current = await Promise.all(turns.map(async turn => await isCurrent(turn) ? turn : null));
    const remaining = current.filter((turn): turn is QuotaTurn => turn !== null);
    return remaining.length === 1 ? remaining[0] : null;
  } catch { return null; }
}
