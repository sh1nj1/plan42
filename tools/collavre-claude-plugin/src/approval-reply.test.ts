import test from "node:test";
import assert from "node:assert/strict";
import { ApprovalWaiter } from "../dist/approval.js";
import { PermissionCoordinator } from "../dist/permission.js";
import { replyWithApprovalHandoff } from "../dist/approval-reply.js";

function state() {
  const waiter = new ApprovalWaiter();
  const coordinator = new PermissionCoordinator();
  const active = { topicId: 42, taskId: 7, defaultTopicId: 1, sessionTopicId: 1 };
  const config = { url: "https://collavre.example", token: "test" };
  return { waiter, coordinator, active, config };
}

test("pending and a decision cached just before reply are handed off; consumed results are not", async t => {
  const { waiter, coordinator, active, config } = state();
  waiter.open("pending");
  waiter.open("cached");
  waiter.settle("cached", { behavior: "deny", reason: "revise" });
  waiter.open("consumed");
  waiter.settle("consumed", { behavior: "allow" });
  await waiter.wait("consumed", 1);
  t.mock.method(globalThis, "fetch", async (_url, init) => {
    assert.deepEqual(JSON.parse(String(init?.body)).pending_approval_ids, ["pending", "cached"]);
    return Response.json({ comment_id: 9, pending_approval_ids: ["pending", "cached"] });
  });
  await replyWithApprovalHandoff(config, 42, "Waiting", 7, "g1", waiter, coordinator, active);
  assert.deepEqual(waiter.openIds(), []);
  assert.equal(active.taskId, null);
});

test("decision and next dispatch during reply do not clear the new turn", async t => {
  const { waiter, coordinator, active, config } = state();
  waiter.open("old");
  coordinator.add("old");
  t.mock.method(globalThis, "fetch", async (_url, init) => {
    assert.deepEqual(JSON.parse(String(init?.body)).pending_approval_ids, ["old"]);
    waiter.settle("old", { behavior: "allow" });
    active.taskId = 8;
    waiter.open("new");
    coordinator.add("new");
    return Response.json({ comment_id: 9, pending_approval_ids: ["old"] });
  });
  await replyWithApprovalHandoff(config, 42, "Waiting", 7, "g1", waiter, coordinator, active);
  assert.deepEqual(waiter.openIds(), ["new"]);
  assert.deepEqual(coordinator.pendingIds(), ["new"]);
  assert.equal(active.taskId, 8);
});

test("failed reply retains local approval and replay tracking", async t => {
  const { waiter, coordinator, active, config } = state();
  waiter.open("pending");
  coordinator.add("pending");
  t.mock.method(globalThis, "fetch", async () => new Response("unavailable", { status: 503 }));
  await assert.rejects(replyWithApprovalHandoff(config, 42, "Waiting", 7, "g1", waiter, coordinator, active));
  assert.deepEqual(waiter.openIds(), ["pending"]);
  assert.deepEqual(coordinator.pendingIds(), ["pending"]);
  assert.equal(active.taskId, 7);
});


test("dispatch before the old reply retains unrelated approvals using server acknowledgments", async t => {
  const { waiter, coordinator, active, config } = state();
  waiter.open("old");
  waiter.open("new");
  coordinator.add("old");
  coordinator.add("new");
  active.taskId = 8;
  t.mock.method(globalThis, "fetch", async (_url, init) => {
    assert.deepEqual(JSON.parse(String(init?.body)).pending_approval_ids, ["old", "new"]);
    return Response.json({ comment_id: 9, pending_approval_ids: ["old"] });
  });
  await replyWithApprovalHandoff(config, 42, "Waiting", 7, "g1", waiter, coordinator, active);
  assert.deepEqual(waiter.openIds(), ["new"]);
  assert.deepEqual(coordinator.pendingIds(), ["new"]);
  assert.equal(active.taskId, 8);
});

test("unacknowledged approvals keep reconnect tracking when replying to the current turn", async t => {
  const { waiter, coordinator, active, config } = state();
  waiter.open("another-turn");
  coordinator.add("another-turn");
  coordinator.add("native-prompt");
  t.mock.method(globalThis, "fetch", async () =>
    Response.json({ comment_id: 9, pending_approval_ids: [] }));
  await replyWithApprovalHandoff(config, 42, "Done", 7, "g1", waiter, coordinator, active);
  assert.deepEqual(waiter.openIds(), ["another-turn"]);
  assert.deepEqual(coordinator.pendingIds(), ["another-turn"]);
});

test("a sibling's already_completed 409 concludes the turn and hands off acknowledged approvals", async t => {
  const { waiter, coordinator, active, config } = state();
  waiter.open("mine");
  waiter.open("foreign");
  coordinator.add("mine");
  coordinator.add("foreign");
  t.mock.method(globalThis, "fetch", async (_url, init) => {
    assert.deepEqual(JSON.parse(String(init?.body)).pending_approval_ids, ["mine", "foreign"]);
    return Response.json({
      error: "Task already completed or not delegated", reason: "already_completed",
      pending_approval_ids: ["mine"],
    }, { status: 409 });
  });
  const result = await replyWithApprovalHandoff(config, 42, "Duplicate", 7, "g1", waiter, coordinator, active);
  assert.equal(result.handled, false);
  assert.equal(active.taskId, null);
  assert.equal(active.topicId, 1);
  assert.deepEqual(waiter.openIds(), ["foreign"]);
  assert.deepEqual(coordinator.pendingIds(), ["foreign"]);
});

test("an already_completed 409 from an older server keeps approvals it did not acknowledge", async t => {
  const { waiter, coordinator, active, config } = state();
  waiter.open("pending");
  t.mock.method(globalThis, "fetch", async () =>
    Response.json({ error: "Task already completed or not delegated", reason: "already_completed" }, { status: 409 }));
  const result = await replyWithApprovalHandoff(config, 42, "Duplicate", 7, "g1", waiter, coordinator, active);
  assert.equal(result.handled, false);
  assert.equal(active.taskId, null);
  assert.deepEqual(waiter.openIds(), ["pending"]);
});

test("a 409 for an unanswered task is raised and keeps the turn", async t => {
  const { waiter, coordinator, active, config } = state();
  t.mock.method(globalThis, "fetch", async () =>
    Response.json({ error: "Task already completed or not delegated", reason: "not_delegated" }, { status: 409 }));
  await assert.rejects(
    replyWithApprovalHandoff(config, 42, "Only copy", 7, "g1", waiter, coordinator, active),
    /Reply failed \(409\)/,
  );
  assert.equal(active.taskId, 7);
});

test("a successful reply reports handled with its comment id", async t => {
  const { waiter, coordinator, active, config } = state();
  t.mock.method(globalThis, "fetch", async () => Response.json({ comment_id: 9, pending_approval_ids: [] }));
  const result = await replyWithApprovalHandoff(config, 42, "Done", 7, "g1", waiter, coordinator, active);
  assert.deepEqual(result, { handled: true, comment_id: 9 });
});
