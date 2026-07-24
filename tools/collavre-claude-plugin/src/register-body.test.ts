import { test } from "node:test";
import assert from "node:assert/strict";
import { buildRegisterBody } from "./collavre-client.ts";

test("register body carries agent_name and session_id separately", () => {
  const body = buildRegisterBody({ agentName: "claude", sessionId: "sess-123" });
  assert.equal(body.agent_name, "claude");
  assert.equal(body.session_id, "sess-123");
});

test("register body includes a legacy composite name for back-compat with old servers", () => {
  // An older server only reads params[:name] (one topic+agent per name). Send a
  // composite so it still registers instead of 400-ing; the new server prefers
  // agent_name/session_id and ignores name.
  const body = buildRegisterBody({ agentName: "claude", sessionId: "sess-123" });
  assert.equal(body.name, "claude-sess-123");
});
