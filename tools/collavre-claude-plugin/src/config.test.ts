import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveAgentName, resolveSessionIdOverride } from "./config.ts";

test("resolveAgentName uses the explicit plugin option when set", () => {
  assert.equal(
    resolveAgentName({ CLAUDE_PLUGIN_OPTION_agent_name: "ops-bot" }),
    "ops-bot",
  );
});

test("resolveAgentName trims whitespace", () => {
  assert.equal(
    resolveAgentName({ CLAUDE_PLUGIN_OPTION_agent_name: "  ops-bot  " }),
    "ops-bot",
  );
});

test("resolveAgentName falls back to the default singleton name when unset/blank", () => {
  // No AGENT_NAME → one shared agent per human (the common case: Claude is
  // just one agent, multi-session under it).
  assert.equal(resolveAgentName({}), "claude");
  assert.equal(resolveAgentName({ CLAUDE_PLUGIN_OPTION_agent_name: "   " }), "claude");
});

test("resolveSessionIdOverride returns a trimmed explicit id or undefined", () => {
  assert.equal(
    resolveSessionIdOverride({ CLAUDE_PLUGIN_OPTION_session_id: " fixed-id " }),
    "fixed-id",
  );
  assert.equal(resolveSessionIdOverride({}), undefined);
  assert.equal(
    resolveSessionIdOverride({ CLAUDE_PLUGIN_OPTION_session_id: "  " }),
    undefined,
  );
});
