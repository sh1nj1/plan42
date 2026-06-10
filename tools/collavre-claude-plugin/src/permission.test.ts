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

test("coordinator expires stale pending requests past the TTL", () => {
  let now = 1_000_000;
  const c = new PermissionCoordinator(60_000, () => now);
  c.add("req-1");
  now += 60_001;
  assert.equal(c.claim("req-1"), false, "expired request must not be claimable");
  assert.equal(c.hasPending("req-1"), false);
});
