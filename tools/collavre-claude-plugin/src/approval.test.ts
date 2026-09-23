import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ApprovalWaiter,
  formatApprovalDecision,
  formatApprovalPending,
  formatApprovalUnknown,
  newApprovalRequestId,
  resolveApprovalWaitMs,
} from "./approval.ts";

test("a decision resolves the parked tool call", async () => {
  const w = new ApprovalWaiter();
  w.open("approval-1");
  const parked = w.wait("approval-1", 5_000);
  assert.equal(w.settle("approval-1", { behavior: "allow", reason: "ok", decided_by: 7 }), true);
  assert.deepEqual(await parked, { behavior: "allow", reason: "ok", decided_by: 7 });
  // consumed: the request is no longer open, so it cannot block the next one
  assert.equal(w.has("approval-1"), false);
  assert.deepEqual(w.openIds(), []);
});

test("a decision arriving between waits is cached, not lost", async () => {
  const w = new ApprovalWaiter();
  w.open("approval-1");
  // the first wait window elapses with nobody having decided
  assert.equal(await w.wait("approval-1", 1), null);
  // the human decides while no tool call is parked
  assert.equal(w.settle("approval-1", { behavior: "deny" }), true);
  // the re-await returns it immediately instead of hanging on a spent broadcast
  assert.deepEqual(await w.wait("approval-1", 1), { behavior: "deny" });
});

test("a timed-out request stays open so the model re-awaits it", async () => {
  const w = new ApprovalWaiter();
  w.open("approval-1");
  assert.equal(await w.wait("approval-1", 1), null);
  assert.equal(w.has("approval-1"), true);
  assert.deepEqual(w.openIds(), ["approval-1"]);
});

test("a foreign or unknown request_id is not settled and never waited on", async () => {
  const w = new ApprovalWaiter();
  w.open("approval-mine");
  // a sibling session's decision on the shared per-agent stream
  assert.equal(w.settle("approval-sibling", { behavior: "allow" }), false);
  assert.equal(w.has("approval-mine"), true);
  // waiting on an id we never raised returns immediately rather than hanging
  assert.equal(await w.wait("approval-sibling", 60_000), null);
});

test("clear releases a parked call so it cannot outlive its turn", async () => {
  const w = new ApprovalWaiter();
  w.open("approval-1");
  const parked = w.wait("approval-1", 60_000);
  w.clear();
  assert.equal(await parked, null);
  assert.equal(w.has("approval-1"), false);
});

test("cancel drops a request whose relay failed", async () => {
  const w = new ApprovalWaiter();
  w.open("approval-1");
  w.cancel("approval-1");
  assert.deepEqual(w.openIds(), []);
});

test("capacity eviction releases the oldest abandoned request", async () => {
  const w = new ApprovalWaiter(1);
  w.open("approval-old");
  const parked = w.wait("approval-old", 60_000);
  w.open("approval-new");
  assert.equal(await parked, null, "the evicted call must not hang forever");
  assert.deepEqual(w.openIds(), ["approval-new"]);
});

test("the wait window follows the client tool timeout", () => {
  assert.equal(resolveApprovalWaitMs({}), 60_000);
  assert.equal(resolveApprovalWaitMs({ MCP_TOOL_TIMEOUT: "100000" }), 80_000);
  for (const value of ["", " ", "nope", "-1", "0", "Infinity"]) {
    assert.equal(resolveApprovalWaitMs({ MCP_TOOL_TIMEOUT: value }), 60_000);
  }
  assert.equal(resolveApprovalWaitMs({ MCP_TOOL_TIMEOUT: "1" }), 1_000);
  assert.equal(resolveApprovalWaitMs({ MCP_TOOL_TIMEOUT: "999999999" }), 3_600_000);
});

test("request ids are namespaced so they cannot collide with a tool prompt id", () => {
  assert.equal(newApprovalRequestId(() => "abc"), "approval-abc");
});

test("a denial is reported as an instruction, not an error", () => {
  const denied = formatApprovalDecision({
    behavior: "deny",
    reason: "too risky",
    decided_by: 7,
    decided_by_name: "Soonoh",
  });
  assert.match(denied, /^denied/);
  assert.match(denied, /Do not perform the denied action/);
  assert.match(denied, /decided_by: Soonoh #7/);
  assert.match(denied, /reason: too risky/);

  const approved = formatApprovalDecision({ behavior: "allow" });
  assert.match(approved, /^approved/);
  // no decider and no reason: those lines are simply absent
  assert.equal(approved.split("\n").length, 1);
});

test("a pending result names the id to re-await and the option to stop", () => {
  const pending = formatApprovalPending("approval-1", 60_000);
  assert.match(pending, /waited 60s/);
  assert.match(pending, /request_id="approval-1"/);
  assert.match(pending, /end your turn/);
  assert.match(formatApprovalUnknown("approval-1"), /No open approval request/);
});
