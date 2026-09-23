import { test } from "node:test";
import assert from "node:assert/strict";
import { ApprovalRelayRejectedError } from "../dist/collavre-client.js";
import { ApprovalWaiter } from "../dist/approval.js";
import { PermissionCoordinator } from "../dist/permission.js";
import { runApprovalRequest, type ApprovalRelayParams } from "../dist/approval-tool.js";

function harness(overrides: { relay?: (p: ApprovalRelayParams) => Promise<unknown> } = {}) {
  const relayed: ApprovalRelayParams[] = [];
  const waiter = new ApprovalWaiter();
  const coordinator = new PermissionCoordinator();
  let n = 0;
  const deps = {
    relay:
      overrides.relay ??
      (async (params: ApprovalRelayParams) => {
        const { signal: _signal, ...body } = params;
        relayed.push(body);
        return { comment_id: 1 };
      }),
    waiter,
    coordinator,
    active: { topicId: 42 as number | null, taskId: 7 as number | null },
    waitMs: 20,
    newRequestId: () => `approval-${++n}`,
  };
  return { deps, relayed, waiter, coordinator };
}

test("the question reaches the active topic and the decision comes back as the result", async () => {
  const { deps, relayed, waiter } = harness();
  deps.waitMs = 5_000;

  const call = runApprovalRequest({ question: "  Deploy to production?  " }, deps);
  // the decision arrives while the tool call is parked
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.deepEqual(relayed, [
    { topicId: 42, requestId: "approval-1", question: "Deploy to production?", taskId: 7, approverUserId: undefined },
  ]);
  waiter.settle("approval-1", { behavior: "allow", decided_by: 3, decided_by_name: "Soonoh" });

  const result = await call;
  assert.equal(result.isError, undefined);
  assert.match(result.content[0].text, /^approved/);
  assert.match(result.content[0].text, /decided_by: Soonoh #3/);
});

test("the request is tracked as a pending permission so a decision survives a WebSocket gap", async () => {
  const { deps, coordinator } = harness();
  await runApprovalRequest({ question: "ok?" }, deps);
  // pull-on-resubscribe asks the server to replay decisions for these ids
  assert.deepEqual(coordinator.pendingIds(), ["approval-1"]);
});

test("a denial is a normal result, not a tool error", async () => {
  const { deps, waiter } = harness();
  deps.waitMs = 5_000;
  const call = runApprovalRequest({ question: "Drop the table?" }, deps);
  await new Promise(resolve => setTimeout(resolve, 5));
  waiter.settle("approval-1", { behavior: "deny", reason: "no" });

  const result = await call;
  assert.equal(result.isError, undefined);
  assert.match(result.content[0].text, /^denied/);
  assert.match(result.content[0].text, /reason: no/);
});

test("an elapsed wait window returns pending and the re-await delivers the decision", async () => {
  const { deps, waiter, relayed } = harness();

  const pending = await runApprovalRequest({ question: "ok?" }, deps);
  assert.equal(pending.isError, undefined, "pending is not a failure — the human is just slow");
  assert.match(pending.content[0].text, /request_id="approval-1"/);

  // the human decides after the call returned, then the model re-awaits
  waiter.settle("approval-1", { behavior: "allow" });
  const resumed = await runApprovalRequest({ request_id: "approval-1" }, deps);
  assert.match(resumed.content[0].text, /^approved/);
  assert.equal(relayed.length, 1, "a re-await must not post a second question");
});

test("a second question while one is undecided points back at the open request", async () => {
  const { deps, relayed } = harness();
  await runApprovalRequest({ question: "first?" }, deps);

  const second = await runApprovalRequest({ question: "second?" }, deps);
  assert.equal(second.isError, true);
  assert.match(second.content[0].text, /already open \(request_id="approval-1"\)/);
  assert.equal(relayed.length, 1, "no duplicate gate is posted into the topic");
});

test("re-awaiting an id this session never raised stops the model looping", async () => {
  const { deps } = harness();
  const result = await runApprovalRequest({ request_id: "approval-gone" }, deps);
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /No open approval request/);
});

test("a blank question, a missing topic, and a bad approver are rejected before relaying", async () => {
  const { deps, relayed } = harness();

  assert.equal((await runApprovalRequest({ question: "   " }, deps)).isError, true);
  assert.equal((await runApprovalRequest({}, deps)).isError, true);
  assert.equal((await runApprovalRequest({ question: "ok?", approver_user_id: "abc" }, deps)).isError, true);

  deps.active.topicId = null;
  const noTopic = await runApprovalRequest({ question: "ok?" }, deps);
  assert.equal(noTopic.isError, true);
  assert.match(noTopic.content[0].text, /No active Collavre topic/);

  assert.deepEqual(relayed, []);
});

test("an explicit approver and a task-less session are both relayed faithfully", async () => {
  const { deps, relayed } = harness();
  deps.active.taskId = null;
  await runApprovalRequest({ question: "ok?", approver_user_id: 9 }, deps);
  assert.deepEqual(relayed, [
    { topicId: 42, requestId: "approval-1", question: "ok?", taskId: undefined, approverUserId: 9 },
  ]);
});

test("a failed relay stops tracking the request so the next one is not blocked", async () => {
  const { deps, waiter, coordinator } = harness({
    relay: async () => {
      throw new ApprovalRelayRejectedError("Approval request failed (403): Not authorized");
    },
  });

  const result = await runApprovalRequest({ question: "ok?" }, deps);
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /Not authorized/);
  // nothing is waiting on a question that never reached the topic
  assert.deepEqual(waiter.openIds(), []);
  assert.deepEqual(coordinator.pendingIds(), []);
});


test("a lost relay response retains the saved request for replay and prevents duplicates", async () => {
  const { deps, waiter, coordinator } = harness({
    relay: async () => { throw new Error("connection lost after save"); },
  });
  const pending = await runApprovalRequest({ question: "ok?" }, deps);
  assert.match(pending.content[0].text, /delivery is unconfirmed/);
  assert.match(pending.content[0].text, /approval-1/);
  assert.deepEqual(coordinator.pendingIds(), ["approval-1"]);
  assert.equal((await runApprovalRequest({ question: "again?" }, deps)).isError, true);
  waiter.settle("approval-1", { behavior: "deny", reason: "later" });
  const result = await runApprovalRequest({ request_id: "approval-1" }, deps);
  assert.match(result.content[0].text, /^denied/);
  assert.match(result.content[0].text, /later/);
});

test("a hung relay is bounded and retains its id because delivery is uncertain", async () => {
  let signal: AbortSignal | undefined;
  const { deps, coordinator } = harness({ relay: async params => {
    signal = params.signal;
    return new Promise(() => {});
  } });
  const result = await runApprovalRequest({ question: "ok?" }, deps);
  assert.match(result.content[0].text, /delivery is unconfirmed/);
  assert.equal(signal?.aborted, true);
  assert.deepEqual(coordinator.pendingIds(), ["approval-1"]);
});

test("relay time is included in the call's wait budget", async () => {
  const { deps } = harness({ relay: async () => {
    await new Promise(resolve => setTimeout(resolve, 400));
    return { comment_id: 1 };
  } });
  deps.waitMs = 1000;
  const started = performance.now();
  const result = await runApprovalRequest({ question: "ok?" }, deps);
  const elapsed = performance.now() - started;
  assert.match(result.content[0].text, /^pending/);
  assert.ok(elapsed < 1250, `must return before the MCP timeout, took ${elapsed}ms`);
});
