import { test } from "node:test";
import assert from "node:assert/strict";
import { decidePreToolUse, isReplyTool, REPLY_TOOL_NAME } from "./hook-decision.ts";

// The dev install names the tool mcp__collavre__reply; a marketplace plugin
// install names it mcp__plugin_collavre_collavre__reply. Auto-approval must
// cover both so the production install path doesn't prompt on every reply.
const MARKETPLACE_REPLY_TOOL_NAME = "mcp__plugin_collavre_collavre__reply";

for (const toolName of [REPLY_TOOL_NAME, MARKETPLACE_REPLY_TOOL_NAME]) {
  test(`auto-approves the Collavre channel reply tool (${toolName})`, () => {
    const decision = decidePreToolUse({ tool_name: toolName });
    assert.ok(decision, "reply tool should produce a decision");
    assert.equal(decision.hookSpecificOutput.hookEventName, "PreToolUse");
    assert.equal(decision.hookSpecificOutput.permissionDecision, "allow");
    assert.ok(
      decision.hookSpecificOutput.permissionDecisionReason.length > 0,
      "decision should carry a human-readable reason",
    );
  });
}

test("isReplyTool matches both install paths and nothing else", () => {
  assert.ok(isReplyTool(REPLY_TOOL_NAME));
  assert.ok(isReplyTool(MARKETPLACE_REPLY_TOOL_NAME));
  // Must not match other servers/tools or partial/substring lookalikes.
  assert.equal(isReplyTool("mcp__collavre__other"), false);
  assert.equal(isReplyTool("mcp__plugin_collavre_collavre__cron_create"), false);
  assert.equal(isReplyTool("mcp__notcollavre__reply"), false);
  assert.equal(isReplyTool("mcp__collavre__reply_extra"), false);
  assert.equal(isReplyTool(undefined), false);
  assert.equal(isReplyTool(null), false);
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
