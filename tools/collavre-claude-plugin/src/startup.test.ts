import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";

test("explicit session starts MCP even when the quota config directory is unwritable", async () => {
  const home = mkdtempSync(join(tmpdir(), "quota-startup-"));
  // A file in place of the directory reliably denies persistence even as root.
  writeFileSync(join(home, ".config"), "");
  const child = spawn(process.execPath, [resolve("dist/index.js")], {
    env: { ...process.env, HOME: home, CLAUDE_PLUGIN_OPTION_session_id: "explicit",
      CLAUDE_PLUGIN_OPTION_url: "http://127.0.0.1:1", CLAUDE_PLUGIN_OPTION_token: "test-only" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", data => { stderr += data; });
  try {
    const response = new Promise<string>((done, reject) => {
      let output = "";
      const timeout = setTimeout(() => reject(Error("MCP initialization timed out")), 5000);
      child.stdout.on("data", data => {
        output += data;
        if (output.includes("\n")) { clearTimeout(timeout); done(output.split("\n")[0]); }
      });
      child.on("exit", () => { clearTimeout(timeout); reject(Error(stderr)); });
    });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "test", version: "1" } } }) + "\n");
    assert.equal(JSON.parse(await response).result.serverInfo.name, "collavre");
    assert.match(stderr, /Quota recovery state is unavailable/);
  } finally {
    child.kill("SIGKILL");
    rmSync(home, { recursive: true, force: true });
  }
});
