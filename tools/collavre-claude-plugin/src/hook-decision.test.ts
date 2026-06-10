import { test } from "node:test";
import assert from "node:assert/strict";
import { decidePreToolUse, REPLY_TOOL_NAME } from "./hook-decision.ts";

test("auto-approves the Collavre channel reply tool", () => {
  const decision = decidePreToolUse({ tool_name: REPLY_TOOL_NAME });
  assert.ok(decision, "reply tool should produce a decision");
  assert.equal(decision.hookSpecificOutput.hookEventName, "PreToolUse");
  assert.equal(decision.hookSpecificOutput.permissionDecision, "allow");
  assert.ok(
    decision.hookSpecificOutput.permissionDecisionReason.length > 0,
    "decision should carry a human-readable reason",
  );
});

test("stays silent (null) for side-effecting tools so they remain gated", () => {
  // Bash/Write/Edit must keep flowing through the normal permission path,
  // which for the channel means the structured approval comment.
  assert.equal(decidePreToolUse({ tool_name: "Bash" }), null);
  assert.equal(decidePreToolUse({ tool_name: "Write" }), null);
  assert.equal(decidePreToolUse({ tool_name: "mcp__collavre__other" }), null);
});

test("stays silent when tool_name is missing or input is malformed", () => {
  assert.equal(decidePreToolUse({}), null);
  assert.equal(decidePreToolUse({ tool_name: undefined }), null);
  // @ts-expect-error — exercising defensive handling of bad input
  assert.equal(decidePreToolUse(null), null);
});
