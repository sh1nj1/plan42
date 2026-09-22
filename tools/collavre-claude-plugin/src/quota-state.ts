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
  constructor(directory: string, pid = process.pid) { this.directory = directory; this.pid = pid; this.save(); }
  add(turn: QuotaTurn): void { this.turns.set(turn.task_id, turn); this.save(); }
  remove(taskId: number): void { this.turns.delete(taskId); this.save(); }
  clear(): void { this.turns.clear(); rmSync(join(this.directory, `${this.pid}.json`), { force: true }); }
  private save(): void {
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const target = join(this.directory, `${this.pid}.json`);
    writeFileSync(`${target}.tmp`, JSON.stringify([...this.turns.values()]), { mode: 0o600 });
    renameSync(`${target}.tmp`, target);
  }
}

export function onlyQuotaTurn(directory: string, alive = (pid: number) => { process.kill(pid, 0); }): QuotaTurn | null {
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
  const turn = turns[0];
  return turns.length === 1 && turn != null && Number.isSafeInteger(turn.task_id) && turn.task_id > 0 &&
    typeof turn.execution_generation === "string" && turn.execution_generation.length > 0 ? turn : null;
}
