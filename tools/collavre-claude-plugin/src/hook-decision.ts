// Claude Code gates EVERY MCP tool call by default — it has no notion that a
// given tool is a harmless outbound message vs. a side-effecting action, and an
// MCP server cannot exempt its own tools (that boundary is owned by the
// harness). The official two-way channels (Telegram/Discord) hit the same wall:
// their `reply` tool prompts every turn unless the user allowlists it by hand.
//
// `reply` is the agent's outbound speech — posting a comment to the topic. In a
// real-time channel, prompting on every answer defeats the channel's purpose.
// This PreToolUse decision auto-approves ONLY `reply`, so no user settings are
// needed for the channel to talk. Side-effecting tools (Bash/Write/Edit/…) are
// deliberately left untouched: they keep flowing through the normal permission
// path, which on the channel surfaces as the structured approval comment.

// The `reply` tool resolves to different fully-qualified names depending on how
// the MCP server was registered:
//   - dev install (`claude mcp add --scope local collavre`): mcp__collavre__reply
//   - marketplace plugin install:               mcp__plugin_collavre_collavre__reply
// Claude Code derives the prefix from the registration path, not the server, so
// the auto-approve gate must accept both — otherwise a marketplace install (the
// production path) prompts on every channel reply.
export const REPLY_TOOL_NAME = "mcp__collavre__reply";
export const REPLY_TOOL_NAME_PATTERN = /^mcp__(?:plugin_collavre_)?collavre__reply$/;

export function isReplyTool(toolName: string | undefined | null): boolean {
  return typeof toolName === "string" && REPLY_TOOL_NAME_PATTERN.test(toolName);
}

export interface PreToolUseInput {
  tool_name?: string;
}

export interface PreToolUseAllow {
  hookSpecificOutput: {
    hookEventName: "PreToolUse";
    permissionDecision: "allow";
    permissionDecisionReason: string;
  };
}

// Returns an allow decision for the channel reply tool, or null for everything
// else (null = emit nothing, let the normal permission flow proceed).
export function decidePreToolUse(input: PreToolUseInput | null | undefined): PreToolUseAllow | null {
  if (!isReplyTool(input?.tool_name)) {
    return null;
  }
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason:
        "Collavre channel reply is outbound chat (posting a comment to the topic), auto-approved. Side-effecting tools remain gated and surface as a structured approval comment.",
    },
  };
}
