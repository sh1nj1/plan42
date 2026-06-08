import { test } from "node:test";
import assert from "node:assert/strict";
import { parseDecision, PermissionCoordinator } from "./permission.ts";

test("parseDecision recognizes canonical allow/deny words", () => {
  assert.equal(parseDecision("allow"), "allow");
  assert.equal(parseDecision("  ALLOW  "), "allow");
  assert.equal(parseDecision("yes"), "allow");
  assert.equal(parseDecision("허용"), "allow");
  assert.equal(parseDecision("승인"), "allow");
  assert.equal(parseDecision("deny"), "deny");
  assert.equal(parseDecision("No"), "deny");
  assert.equal(parseDecision("거부"), "deny");
});

test("parseDecision returns null for non-decisions (forward as normal message)", () => {
  assert.equal(parseDecision("what is the session id?"), null);
  assert.equal(parseDecision("no idea what that means"), null);
  assert.equal(parseDecision("yes please also run the tests"), null);
  assert.equal(parseDecision(""), null);
});

test("coordinator resolves the pending request for a topic with a decision reply", () => {
  const c = new PermissionCoordinator();
  c.add(28, "req-1");
  const decision = c.tryResolve(28, "allow");
  assert.deepEqual(decision, { request_id: "req-1", behavior: "allow" });
  // consumed — a second reply finds nothing pending
  assert.equal(c.tryResolve(28, "deny"), null);
});

test("coordinator does not resolve a non-decision reply (message forwarded normally)", () => {
  const c = new PermissionCoordinator();
  c.add(28, "req-1");
  assert.equal(c.tryResolve(28, "actually, what does that command do?"), null);
  // still pending — the prompt remains open for a later explicit answer
  assert.equal(c.hasPending(28), true);
});

test("coordinator returns null when no request is pending for the topic", () => {
  const c = new PermissionCoordinator();
  c.add(99, "req-other");
  assert.equal(c.tryResolve(28, "allow"), null);
});

test("coordinator resolves multiple pending requests FIFO (sequential tool prompts)", () => {
  const c = new PermissionCoordinator();
  c.add(28, "req-1");
  c.add(28, "req-2");
  assert.deepEqual(c.tryResolve(28, "allow"), { request_id: "req-1", behavior: "allow" });
  assert.deepEqual(c.tryResolve(28, "deny"), { request_id: "req-2", behavior: "deny" });
});

test("coordinator expires stale pending requests past the TTL", () => {
  let now = 1_000_000;
  const c = new PermissionCoordinator(60_000, () => now);
  c.add(28, "req-1");
  now += 60_001;
  assert.equal(c.tryResolve(28, "allow"), null, "expired request must not resolve");
  assert.equal(c.hasPending(28), false);
});
