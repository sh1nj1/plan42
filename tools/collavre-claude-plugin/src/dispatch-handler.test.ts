import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "@modelcontextprotocol/sdk/server/index.js";
import type { CollavreClient } from "../dist/collavre-client.js";
import { makeEventHandler } from "../dist/dispatch-handler.js";
import { PermissionCoordinator } from "../dist/permission.js";
import { ApprovalWaiter } from "../dist/approval.js";
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
  const handler = makeEventHandler(server, client, new PermissionCoordinator(), new ApprovalWaiter(), active, false, state);
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

test("an approval decision resolves the waiting tool call instead of being sent to Claude Code", async () => {
  const directory = mkdtempSync(join(tmpdir(), "quota-approval-"));
  const state = new QuotaState(directory);
  const sent: unknown[] = [];
  const server = { notification: async (n: unknown) => { sent.push(n); } } as unknown as Server;
  const client = {} as unknown as CollavreClient;
  const active = { topicId: 2, taskId: 1, defaultTopicId: 2, sessionTopicId: 2 };
  const coordinator = new PermissionCoordinator();
  const waiter = new ApprovalWaiter();
  const handler = makeEventHandler(server, client, coordinator, waiter, active, false, state);

  // An agent-initiated approval request: tracked by both (the coordinator drives
  // the resubscribe replay, the waiter parks the tool call).
  coordinator.add("approval-1");
  waiter.open("approval-1");
  const parked = waiter.wait("approval-1", 5_000);

  await handler({ type: "permission_decision", request_id: "approval-1", behavior: "deny",
    reason: "not now", decided_by: 3, decided_by_name: "Soonoh" });

  assert.deepEqual(await parked, { behavior: "deny", reason: "not now", decided_by: 3, decided_by_name: "Soonoh" });
  // Claude Code has no permission prompt for this id — forwarding one would be rejected
  assert.deepEqual(sent, []);
  // consumed, so the resubscribe replay stops asking the server to redeliver it
  assert.deepEqual(coordinator.pendingIds(), []);

  // A relayed native tool prompt still takes the permission path.
  coordinator.add("req-tool");
  await handler({ type: "permission_decision", request_id: "req-tool", behavior: "allow" });
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0], {
    method: "notifications/claude/channel/permission",
    params: { request_id: "req-tool", behavior: "allow" },
  });

  state.clear();
  rmSync(directory, { recursive: true, force: true });
});

test("continuation clears the old approval after a lost reply response", async () => {
  const directory = mkdtempSync(join(tmpdir(), "approval-handoff-"));
  const state = new QuotaState(directory);
  const sent: unknown[] = [];
  const server = { notification: async (n: unknown) => { sent.push(n); } } as unknown as Server;
  const client = { quotaTurnCurrent: async () => true } as unknown as CollavreClient;
  const active = { topicId: 2, taskId: 1, defaultTopicId: 2, sessionTopicId: 2 };
  const coordinator = new PermissionCoordinator();
  const waiter = new ApprovalWaiter();
  waiter.open("old");
  waiter.open("other");
  coordinator.add("old");
  coordinator.add("other");
  const handler = makeEventHandler(server, client, coordinator, waiter, active, false, state);
  try {
    await handler({
      type: "dispatch", task_id: 3, approval_request_id: "old",
      comment: { id: 4, topic_id: 2, creative_id: 5, author_id: 6, author_name: "Claude", content: "Decision" },
    });
    assert.deepEqual(waiter.openIds(), ["other"]);
    assert.deepEqual(coordinator.pendingIds(), ["other"]);
    assert.equal(active.taskId, 3);
    assert.equal(sent.length, 1);
  } finally { state.clear(); rmSync(directory, { recursive: true, force: true }); }
});
