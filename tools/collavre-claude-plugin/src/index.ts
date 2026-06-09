#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { hostname } from "os";
import { CollavreClient } from "./collavre-client.js";
import { CableSubscriber, type AgentEvent } from "./cable-subscriber.js";
import { loadConfig } from "./config.js";
import {
  PermissionCoordinator,
  formatPermissionPrompt,
  type Behavior,
} from "./permission.js";

// Native Claude Channel permission relay (CC v2.1.168+). When the
// `claude/channel/permission` capability is declared, Claude Code relays each
// mid-turn tool permission prompt to this server via this notification (in
// addition to the local TUI dialog). request_id correlates the eventual
// decision; the payload carries no topic, so we map it to the active dispatch.
const PERMISSION_REQUEST_METHOD =
  "notifications/claude/channel/permission_request";
const PERMISSION_DECISION_METHOD = "notifications/claude/channel/permission";

const PermissionRequestNotificationSchema = z.object({
  method: z.literal(PERMISSION_REQUEST_METHOD),
  params: z.object({
    request_id: z.coerce.string(),
    tool_name: z.string().optional(),
    description: z.string().optional(),
    input_preview: z.unknown().optional(),
  }),
});

function buildAgentName(): string {
  // pid is unique among concurrent processes on the same machine, so
  // running multiple Claude Code sessions in parallel cannot collide.
  return `${hostname().split(".")[0]}-${process.pid}`;
}

function errorResult(message: string) {
  return {
    content: [{ type: "text" as const, text: message }],
    isError: true as const,
  };
}

function buildServer(client: CollavreClient, active: ActiveContext): Server {
  const server = new Server(
    { name: "collavre", version: "0.1.0" },
    {
      capabilities: {
        experimental: {
          "claude/channel": {},
          // Opt into native permission relay: Claude Code only routes
          // permission_request notifications to channel servers that declare
          // BOTH capabilities (gated by the tengu_harbor_permissions flag).
          "claude/channel/permission": {},
        },
        tools: {},
      },
      instructions: [
        'Messages from Collavre arrive as <channel source="collavre" topic_id="..." author="..." comment_id="..." task_id="...">.',
        "Reply using the reply tool, passing topic_id AND task_id from the tag",
        "(task_id correlates the reply with the exact dispatched task when",
        "multiple delegated tasks can be in flight on the same topic).",
        'Never reply to your own messages (author starts with "claude-").',
      ].join("\n"),
    },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "reply",
        description: "Send a reply message to the Collavre channel topic",
        inputSchema: {
          type: "object" as const,
          properties: {
            topic_id: {
              type: "number",
              description: "Topic ID from the channel message meta",
            },
            text: {
              type: "string",
              description: "The message text to send",
            },
            task_id: {
              type: "number",
              description:
                "Task ID echoed from the dispatch notification meta. Required: when topic concurrency > 1 multiple delegated tasks can coexist, and replies must correlate to the exact dispatched task — omitting this would let the server fall back to the oldest delegated task and complete the wrong one.",
            },
          },
          required: ["topic_id", "text", "task_id"],
        },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    if (req.params.name !== "reply") {
      return errorResult(`Unknown tool: ${req.params.name}`);
    }

    const args = req.params.arguments;
    if (!args || typeof args !== "object") {
      return errorResult("Invalid arguments");
    }
    const record = args as Record<string, unknown>;
    const topicId = Number(record.topic_id);
    const text = record.text;
    if (!Number.isFinite(topicId)) {
      return errorResult("topic_id must be a number");
    }
    if (typeof text !== "string" || text.length === 0) {
      return errorResult("text must be a non-empty string");
    }
    if (record.task_id === undefined || record.task_id === null) {
      return errorResult(
        "task_id is required — echo the task_id from the dispatch notification meta so the server completes the exact delegated task",
      );
    }
    const taskId = Number(record.task_id);
    if (!Number.isFinite(taskId)) {
      return errorResult("task_id must be a number");
    }

    const result = await client.reply(topicId, text, taskId);

    // The dispatched turn is concluding (Claude has replied). Reset the active
    // context to the registration inbox default so a subsequent locally-
    // initiated turn's permission prompt surfaces in the inbox rather than
    // leaking into this just-finished work topic.
    active.topicId = active.defaultTopicId;
    active.taskId = null;

    return {
      content: [
        { type: "text" as const, text: `Sent (comment #${result.comment_id})` },
      ],
    };
  });

  return server;
}

// Tracks the most recently forwarded dispatch so an incoming permission_request
// (which carries no topic or task) can be surfaced into the right topic AND
// authorized as the dispatched agent. A Claude Code session processes one turn
// at a time, so the last forwarded dispatch is the turn whose tool is now
// awaiting permission.
//
// taskId is the dispatch's delegated task: the server authorizes /notify
// against it so prompts raised on a *work* topic (where this session is not the
// topic's primary_agent, having been matched via routing_expression) still
// surface — topic.primary_agent alone would 403 there.
//
// defaultTopicId is the registration inbox topic. After a turn ends (the reply
// tool is called) topicId/taskId reset to this default so a subsequent locally-
// initiated turn's prompt surfaces in the inbox instead of leaking into the
// just-finished work topic (and so a normal reply there is not consumed as a
// permission decision).
interface ActiveContext {
  topicId: number | null;
  taskId: number | null;
  defaultTopicId: number | null;
}

async function sendPermissionDecision(
  server: Server,
  requestId: string,
  behavior: Behavior,
): Promise<void> {
  await server.notification({
    method: PERMISSION_DECISION_METHOD,
    params: { request_id: requestId, behavior },
  });
}

function decisionAck(behavior: Behavior): string {
  return behavior === "allow"
    ? "🔓 권한 승인됨 — 계속 진행합니다."
    : "🚫 권한 거부됨.";
}

function makeEventHandler(
  server: Server,
  client: CollavreClient,
  coordinator: PermissionCoordinator,
  active: ActiveContext,
  debug: boolean,
) {
  return async (event: AgentEvent): Promise<void> => {
    if (event.type !== "dispatch" || !event.comment) {
      if (debug) {
        process.stderr.write(
          `[collavre] Ignoring non-dispatch event: ${JSON.stringify(event).slice(0, 200)}\n`,
        );
      }
      return;
    }

    const topicId = event.comment.topic_id;

    // If this comment answers a permission prompt awaiting a decision, consume
    // it as allow/deny instead of forwarding it to Claude — Claude is suspended
    // on the permission and cannot act on a normal message. The decision
    // unblocks the original turn; we then complete the task this reply spawned
    // so it does not hang delegated.
    const decision = coordinator.tryResolve(topicId, event.comment.content);
    if (decision) {
      process.stderr.write(
        `[collavre] Permission decision from comment #${event.comment.id}: ${decision.behavior} (request_id=${decision.request_id})\n`,
      );
      try {
        await sendPermissionDecision(server, decision.request_id, decision.behavior);
      } catch (err) {
        process.stderr.write(
          `[collavre] Failed to send permission decision: ${err instanceof Error ? err.stack : err}\n`,
        );
      }
      if (event.task_id != null) {
        try {
          await client.reply(topicId, decisionAck(decision.behavior), event.task_id);
        } catch (err) {
          process.stderr.write(
            `[collavre] Failed to complete decision task: ${err instanceof Error ? err.message : err}\n`,
          );
        }
      }
      return;
    }

    process.stderr.write(
      `[collavre] Dispatch: comment #${event.comment.id} by ${event.comment.author_name} (id=${event.comment.author_id}) task_id=${event.task_id ?? "none"}\n`,
    );

    // Record the active turn's topic AND delegated task so a permission_request
    // relayed during it can be surfaced into this topic and authorized as the
    // dispatched agent (work topics where this session is not primary_agent).
    active.topicId = topicId;
    active.taskId = event.task_id ?? null;

    try {
      const meta: Record<string, string> = {
        topic_id: String(event.comment.topic_id),
        comment_id: String(event.comment.id),
        author: event.comment.author_name,
        author_id: String(event.comment.author_id),
      };
      if (event.task_id != null) {
        meta.task_id = String(event.task_id);
      }
      await server.notification({
        method: "notifications/claude/channel" as const,
        params: {
          content: event.comment.content,
          meta,
        },
      });
      process.stderr.write(`[collavre] Notification sent OK\n`);
    } catch (err) {
      process.stderr.write(
        `[collavre] Failed to forward message: ${err instanceof Error ? err.stack : err}\n`,
      );
    }
  };
}

async function main(): Promise<void> {
  const debug = process.env.COLLAVRE_DEBUG === "1";
  const config = loadConfig();
  process.stderr.write(`[collavre] Config loaded: url=${config.url}\n`);

  const client = new CollavreClient(config);
  const agentName = buildAgentName();

  const coordinator = new PermissionCoordinator();
  const active: ActiveContext = {
    topicId: null,
    taskId: null,
    defaultTopicId: null,
  };
  const server = buildServer(client, active);

  // Surface relayed tool-permission prompts into the active topic so the user
  // can approve/deny from Collavre. Registered before connect so the handler
  // is live as soon as Claude Code starts relaying. The local TUI dialog still
  // works in parallel — this is additive (first responder wins).
  server.setNotificationHandler(
    PermissionRequestNotificationSchema,
    async (notif) => {
      const { request_id, tool_name, description, input_preview } = notif.params;
      const topicId = active.topicId;
      if (topicId == null) {
        process.stderr.write(
          `[collavre] permission_request (${tool_name ?? "tool"}) with no active topic — leaving to local TUI\n`,
        );
        return;
      }
      const taskId = active.taskId;
      coordinator.add(topicId, request_id);
      try {
        await client.notify(
          topicId,
          formatPermissionPrompt({ request_id, tool_name, description, input_preview }),
          taskId ?? undefined,
          request_id,
        );
        process.stderr.write(
          `[collavre] permission_request relayed to topic #${topicId}: ${tool_name ?? "tool"} (request_id=${request_id})\n`,
        );
      } catch (err) {
        process.stderr.write(
          `[collavre] Failed to relay permission_request: ${err instanceof Error ? err.message : err}\n`,
        );
      }
    },
  );

  // Connect stdio transport FIRST — Claude Code sends an MCP initialize
  // request immediately after spawning this process and will timeout if
  // we block on network calls before reading stdin.
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write("[collavre] MCP server started\n");

  // Open the WebSocket before register() to minimize (but not eliminate)
  // the window where comments posted between register() and subscribeTo()
  // could be lost. Closing the gap entirely requires the server to replay
  // missed messages on subscription confirm.
  const cable = new CableSubscriber(
    config.url,
    config.token,
    makeEventHandler(server, client, coordinator, active, debug),
    debug,
  );
  await cable.connect();
  process.stderr.write("[collavre] WebSocket ready\n");

  const reg = await client.register(agentName);
  process.stderr.write(
    `[collavre] Registered: ${reg.agent_name} (agent #${reg.agent_id}) → inbox topic #${reg.topic_id} (${reg.topic_name})\n`,
  );

  // Default permission prompts to the registration inbox topic so a
  // locally-initiated turn (typed in the Claude Code REPL, not a channel
  // dispatch) still surfaces its prompt somewhere visible. Each incoming
  // dispatch overrides this with that dispatch's topic/task; the reply tool
  // resets back to this default when the dispatched turn ends. The inbox
  // default carries no task — the session is the inbox topic's primary_agent,
  // so /notify authorizes via topic.primary_agent there.
  active.defaultTopicId = reg.topic_id;
  active.topicId = reg.topic_id;

  // Subscribe by agent_id, not topic_id. Comments in the registration inbox
  // are skipped by Comment#dispatch_to_orchestration; real dispatches arrive
  // on the per-agent stream regardless of which topic triggered them.
  cable.subscribeToAgent(reg.agent_id);

  const cleanup = async () => {
    cable.disconnect();
    await client.unregister(reg.agent_id, reg.topic_id);
    process.exit(0);
  };

  process.on("SIGTERM", cleanup);
  process.on("SIGINT", cleanup);
}

main().catch((err) => {
  process.stderr.write(
    `[collavre] Fatal: ${err instanceof Error ? err.message : err}\n`,
  );
  process.exit(1);
});
