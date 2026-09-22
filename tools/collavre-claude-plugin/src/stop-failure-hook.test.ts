import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { QuotaState, quotaDirectory } from "./quota-state.ts";

test("StopFailure command sends authenticated suspension without invoking a model", async () => {
  const home = mkdtempSync(join(tmpdir(), "quota-hook-"));
  const cwd = join(home, "workspace");
  const state = new QuotaState(quotaDirectory(cwd, join(home, ".config/collavre/sessions")));
  state.add({ task_id: 41, execution_generation: "cancelled" });
  state.add({ task_id: 42, execution_generation: "generation-a" });
  const requests: unknown[] = [];
  const server = createServer(async (req, res) => {
    if (req.method === "GET") {
      assert.equal(req.headers.authorization, "Bearer test-only");
      res.writeHead(200).end(JSON.stringify({ current: req.url?.includes("/42/") }));
      return;
    }
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk);
    requests.push({ path: req.url, authorization: req.headers.authorization, body: JSON.parse(Buffer.concat(chunks).toString()) });
    res.writeHead(200).end('{}');
  });
  try {
    await new Promise<void>(done => server.listen(0, "127.0.0.1", done));
    const address = server.address();
    assert(address && typeof address !== "string");
    const child = spawn(process.execPath, [resolve("dist/stop-failure-hook.js")], {
      env: { ...process.env, HOME: home, CLAUDE_PLUGIN_OPTION_url: `http://127.0.0.1:${address.port}`, CLAUDE_PLUGIN_OPTION_token: "test-only" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    child.stdin.end(JSON.stringify({ cwd, hook_event_name: "StopFailure", error: "rate_limit", last_assistant_message: "You've hit your limit · resets 5pm" }));
    const code = await new Promise<number | null>(done => child.on("exit", done));
    assert.equal(code, 0);
    assert.deepEqual(requests, [{ path: "/api/v1/agent/tasks/42/suspend", authorization: "Bearer test-only", body: { reason: "quota", execution_generation: "generation-a" } }]);
  } finally {
    server.close();
    rmSync(home, { recursive: true, force: true });
  }
});
