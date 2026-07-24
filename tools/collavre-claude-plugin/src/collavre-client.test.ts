import { test } from "node:test";
import assert from "node:assert/strict";
import { isBenignReplyDedup } from "./collavre-client.ts";

test("a sibling session's completed-task conflict is benign", () => {
  // The dispatch fanned out to two sessions sharing one agent; the other won the
  // atomic claim and posted. Nothing of ours is lost by staying quiet.
  assert.equal(
    isBenignReplyDedup(
      JSON.stringify({ error: "Task already completed or not delegated", reason: "already_completed" }),
    ),
    true,
  );
});

test("a cancelled/failed/recovered task conflict is NOT benign", () => {
  // Nobody answered this dispatch — the reply in hand is the only copy of it.
  assert.equal(
    isBenignReplyDedup(
      JSON.stringify({ error: "Task already completed or not delegated", reason: "not_delegated" }),
    ),
    false,
  );
});

test("a task claimed but not yet answered is NOT benign", () => {
  // The server flips the task to done before the reply comment is saved. A 409
  // from inside that window has no answer behind it — and the window can end in
  // a rollback — so this reply is still the only copy.
  assert.equal(
    isBenignReplyDedup(
      JSON.stringify({
        error: "Task already completed or not delegated",
        reason: "claimed_without_reply",
      }),
    ),
    false,
  );
});

test("a legacy server that sends no reason is NOT benign", () => {
  // Back-compat runs the safe way: surface the conflict, as this client did
  // before dedup existed, rather than silently dropping a possibly-valid reply.
  assert.equal(
    isBenignReplyDedup(JSON.stringify({ error: "Task already completed or not delegated" })),
    false,
  );
});

test("a non-JSON body is NOT benign", () => {
  assert.equal(isBenignReplyDedup("<html>502 Bad Gateway</html>"), false);
  assert.equal(isBenignReplyDedup(""), false);
});
