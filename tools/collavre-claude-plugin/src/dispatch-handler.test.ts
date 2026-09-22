import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "@modelcontextprotocol/sdk/server/index.js";
import type { CollavreClient } from "../dist/collavre-client.js";
import { makeEventHandler } from "../dist/dispatch-handler.js";
import { PermissionCoordinator } from "../dist/permission.js";
import { QuotaState, onlyQuotaTurn } from "../dist/quota-state.js";

test("a rejected notification is never a quota turn, but a delivered retry is", async () => {
  const directory = mkdtempSync(join(tmpdir(), "quota-dispatch-"));
  const state = new QuotaState(directory);
  const turn = { task_id: 42, execution_generation: "attempt-2" };
  let reject = true;
  const server = { notification: async () => {
    assert.equal(onlyQuotaTurn(directory), null, "tracking must wait for transport success");
    if (reject) throw Error("transport closed");
  } } as unknown as Server;
  const client = { quotaTurnCurrent: async () => true } as unknown as CollavreClient;
  const active = { topicId: null, taskId: null, defaultTopicId: null, sessionTopicId: null };
  const handler = makeEventHandler(server, client, new PermissionCoordinator(), active, false, state);
  const event = { type: "dispatch" as const, ...turn,
    comment: { id: 1, topic_id: 2, author_id: 3, author_name: "User", content: "Request" } };
  try {
    await handler(event);
    assert.equal(onlyQuotaTurn(directory), null);
    reject = false;
    await handler(event);
    assert.deepEqual(onlyQuotaTurn(directory), turn);
  } finally { state.clear(); rmSync(directory, { recursive: true, force: true }); }
});
