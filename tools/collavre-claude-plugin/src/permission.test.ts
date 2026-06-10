import { test } from "node:test";
import assert from "node:assert/strict";
import { PermissionCoordinator } from "./permission.ts";

test("coordinator claims a request this session surfaced", () => {
  const c = new PermissionCoordinator();
  c.add("req-1");
  assert.equal(c.hasPending("req-1"), true);
  assert.equal(c.claim("req-1"), true);
  // consumed — a second decision for the same request finds nothing
  assert.equal(c.claim("req-1"), false);
  assert.equal(c.hasPending("req-1"), false);
});

test("coordinator does not claim a request it never surfaced (sibling session)", () => {
  const c = new PermissionCoordinator();
  c.add("req-mine");
  assert.equal(c.claim("req-foreign"), false);
  // still pending — the foreign decision did not consume our request
  assert.equal(c.hasPending("req-mine"), true);
});

test("coordinator tracks multiple concurrent requests independently", () => {
  const c = new PermissionCoordinator();
  c.add("req-1");
  c.add("req-2");
  assert.equal(c.claim("req-2"), true);
  assert.equal(c.claim("req-1"), true);
  assert.equal(c.claim("req-2"), false);
});

test("coordinator never expires a pending request by time (late approval still claimable)", () => {
  // Regression: a human may click approve/deny minutes or hours after the
  // prompt is surfaced. The decision must still be claimed — there is no
  // wall-clock TTL — otherwise the suspended turn hangs with no retry path.
  const c = new PermissionCoordinator();
  c.add("req-1");
  assert.equal(c.hasPending("req-1"), true);
  assert.equal(
    c.claim("req-1"),
    true,
    "a late decision must still be claimable",
  );
});

test("coordinator bounds memory by capacity, evicting the oldest entries", () => {
  const c = new PermissionCoordinator(3);
  c.add("req-1");
  c.add("req-2");
  c.add("req-3");
  c.add("req-4"); // exceeds cap → evicts the oldest (req-1)
  assert.equal(c.hasPending("req-1"), false, "oldest entry evicted past cap");
  assert.equal(c.hasPending("req-2"), true);
  assert.equal(c.hasPending("req-3"), true);
  assert.equal(c.hasPending("req-4"), true);
});

test("coordinator re-surfacing an id refreshes its eviction position", () => {
  const c = new PermissionCoordinator(2);
  c.add("req-1");
  c.add("req-2");
  c.add("req-1"); // re-surface → req-1 becomes newest, req-2 now oldest
  c.add("req-3"); // exceeds cap → evicts req-2
  assert.equal(c.hasPending("req-2"), false);
  assert.equal(c.hasPending("req-1"), true);
  assert.equal(c.hasPending("req-3"), true);
});
