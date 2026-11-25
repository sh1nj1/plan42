import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { QuotaState, currentQuotaTurn, onlyQuotaTurn, quotaDirectory } from "./quota-state.ts";

test("duplicate dispatch is idempotent and a new generation replaces old state", () => {
  const dir = mkdtempSync(join(tmpdir(), "quota-"));
  try {
    const state = new QuotaState(dir);
    const turn = { task_id: 1, execution_generation: "first" };
    state.add(turn); state.add(turn);
    assert.deepEqual(onlyQuotaTurn(dir), turn);
    state.add({ ...turn, execution_generation: "second" });
    assert.equal(onlyQuotaTurn(dir)?.execution_generation, "second");
    state.remove(1);
    assert.equal(onlyQuotaTurn(dir), null);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test("multiple queued turns or sibling sessions are ambiguous; dead processes are ignored", () => {
  const dir = mkdtempSync(join(tmpdir(), "quota-"));
  try {
    const first = new QuotaState(dir, 11), second = new QuotaState(dir, 22);
    first.add({ task_id: 1, execution_generation: "a" });
    first.add({ task_id: 2, execution_generation: "b" });
    assert.equal(onlyQuotaTurn(dir, () => {}), null);
    first.remove(2); second.add({ task_id: 3, execution_generation: "c" });
    assert.equal(onlyQuotaTurn(dir, () => {}), null);
    assert.equal(onlyQuotaTurn(dir, pid => { if (pid === 22) throw Object.assign(Error(), { code: "ESRCH" }); })?.task_id, 1);
    first.clear(); second.clear();
    assert.equal(onlyQuotaTurn(dir), null);
    assert.notEqual(quotaDirectory("/a", dir), quotaDirectory("/b", dir));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("an idle sibling session makes failure attribution ambiguous", () => {
  const dir = mkdtempSync(join(tmpdir(), "quota-"));
  try {
    const first = new QuotaState(dir, 11), second = new QuotaState(dir, 22);
    first.add({ task_id: 1, execution_generation: "a" });
    assert.equal(onlyQuotaTurn(dir, () => {}), null);
    second.clear();
    assert.equal(onlyQuotaTurn(dir, () => {})?.task_id, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("server pruning removes terminal turns but preserves uncertain and newer executions", async () => {
  const dir = mkdtempSync(join(tmpdir(), "quota-"));
  try {
    const state = new QuotaState(dir);
    state.add({ task_id: 1, execution_generation: "cancelled" });
    state.add({ task_id: 2, execution_generation: "current" });
    assert.equal((await currentQuotaTurn(dir, async turn => turn.task_id === 2))?.task_id, 2);
    assert.equal(await currentQuotaTurn(dir, async () => { throw Error("offline"); }), null);
    await state.prune(async turn => turn.task_id === 2);
    assert.equal(onlyQuotaTurn(dir)?.task_id, 2);
    await state.prune(async () => { throw Error("transient reply failure"); });
    assert.equal(onlyQuotaTurn(dir)?.task_id, 2);
    await state.prune(async () => {
      state.add({ task_id: 2, execution_generation: "newer" });
      return false;
    });
    assert.equal(onlyQuotaTurn(dir)?.execution_generation, "newer");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("unwritable persistence never interrupts initialization dispatch reply or cleanup", () => {
  const root = mkdtempSync(join(tmpdir(), "quota-"));
  try {
    const file = join(root, "not-a-directory");
    writeFileSync(file, "");
    const state = new QuotaState(join(file, "sessions"));
    assert.doesNotThrow(() => {
      state.add({ task_id: 1, execution_generation: "a" });
      state.remove(1);
      state.clear();
    });
    assert.equal(onlyQuotaTurn(join(file, "sessions")), null);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("confirmed dead PID files are removed before PID reuse, including ambiguous scans", () => {
  const dir = mkdtempSync(join(tmpdir(), "quota-"));
  try {
    const first = new QuotaState(dir, 11), sibling = new QuotaState(dir, 22);
    new QuotaState(dir, 33);
    first.add({ task_id: 1, execution_generation: "current" });
    assert.equal(onlyQuotaTurn(dir, pid => {
      if (pid === 33) throw Object.assign(Error(), { code: "ESRCH" });
    }), null);
    assert.equal(existsSync(join(dir, "33.json")), false);
    sibling.clear();
    assert.equal(onlyQuotaTurn(dir, () => {})?.task_id, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("unconfirmed liveness failures preserve state and refuse attribution", () => {
  const dir = mkdtempSync(join(tmpdir(), "quota-"));
  try {
    new QuotaState(dir, 11).add({ task_id: 1, execution_generation: "current" });
    new QuotaState(dir, 22);
    for (const code of ["EPERM", "EIO"]) {
      assert.equal(onlyQuotaTurn(dir, pid => {
        if (pid === 22) throw Object.assign(Error(), { code });
      }), null);
      assert.equal(existsSync(join(dir, "22.json")), true);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
