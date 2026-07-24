import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, writeFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { resolveSessionId } from "./session.ts";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function withTempDir<T>(fn: (dir: string) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "collavre-session-"));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("generates a uuid for a cwd and persists it (resume returns the same id)", () => {
  withTempDir((stateDir) => {
    const first = resolveSessionId({ cwd: "/home/me/project", stateDir });
    assert.match(first, UUID_RE);

    // Simulate a --resume: same cwd, fresh call, must restore the same id.
    const second = resolveSessionId({ cwd: "/home/me/project", stateDir });
    assert.equal(second, first);
  });
});

test("different cwd yields a different session id", () => {
  withTempDir((stateDir) => {
    const a = resolveSessionId({ cwd: "/home/me/project-a", stateDir });
    const b = resolveSessionId({ cwd: "/home/me/project-b", stateDir });
    assert.notEqual(a, b);
  });
});

test("explicit override is returned verbatim and never persisted", () => {
  withTempDir((stateDir) => {
    const id = resolveSessionId({
      cwd: "/home/me/project",
      stateDir,
      override: "my-fixed-session",
    });
    assert.equal(id, "my-fixed-session");
    // No state file should be written for an explicit override.
    assert.equal(readdirSync(stateDir).length, 0);
  });
});

test("blank override falls through to cwd-derived persistence", () => {
  withTempDir((stateDir) => {
    const id = resolveSessionId({
      cwd: "/home/me/project",
      stateDir,
      override: "   ",
    });
    assert.match(id, UUID_RE);
  });
});

test("a corrupted (empty) state file is regenerated rather than returned blank", () => {
  withTempDir((stateDir) => {
    const id1 = resolveSessionId({ cwd: "/home/me/project", stateDir });
    // Find the persisted file and blank it out (simulate truncation).
    const files = readdirSync(stateDir);
    assert.equal(files.length, 1);
    writeFileSync(join(stateDir, files[0]), "   \n");

    const id2 = resolveSessionId({ cwd: "/home/me/project", stateDir });
    assert.match(id2, UUID_RE);
    assert.notEqual(id2, "");
  });
});
