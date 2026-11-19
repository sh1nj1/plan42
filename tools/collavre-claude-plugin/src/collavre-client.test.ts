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

test("an unrecognized reason is NOT benign", () => {
  // Only the one marker the server reserves for an answered dispatch may
  // suppress; anything new defaults to surfacing the reply.
  assert.equal(
    isBenignReplyDedup(
      JSON.stringify({ error: "Task already completed or not delegated", reason: "something_else" }),
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
