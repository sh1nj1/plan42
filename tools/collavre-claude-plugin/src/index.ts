#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { basename } from "path";
import { CollavreClient } from "./collavre-client.js";
import { CableSubscriber } from "./cable-subscriber.js";
import { loadConfig } from "./config.js";
import { resolveSessionId, defaultSessionStateDir } from "./session.js";
import { makeEventHandler, type ActiveContext } from "./dispatch-handler.js";
import { QuotaState, quotaDirectory } from "./quota-state.js";
const quotaState = new QuotaState(quotaDirectory(process.cwd()));

import { PermissionCoordinator } from "./permission.js";
import { ApprovalWaiter, newApprovalRequestId, resolveApprovalWaitMs } from "./approval.js";
import { replyWithApprovalHandoff } from "./approval-reply.js";
import type { CollavreConfig } from "./config.js";
import { runApprovalRequest } from "./approval-tool.js";
import { randomUUID } from "crypto";

// Native Claude Channel permission relay (CC v2.1.168+). When the
// `claude/channel/permission` capability is declared, Claude Code relays each
// mid-turn tool permission prompt to this server via this notification (in
// addition to the local TUI dialog). request_id correlates the eventual
// decision; the payload carries no topic, so we map it to the active dispatch.
const PERMISSION_REQUEST_METHOD =
  "notifications/claude/channel/permission_request";

const PermissionRequestNotificationSchema = z.object({
  method: z.literal(PERMISSION_REQUEST_METHOD),
  params: z.object({
    request_id: z.coerce.string(),
    tool_name: z.string().optional(),
    description: z.string().optional(),
    input_preview: z.unknown().optional(),
  }),
});

function errorResult(message: string) {
  return {
    content: [{ type: "text" as const, text: message }],
    isError: true as const,
  };
}

function buildServer(
  client: CollavreClient,
  active: ActiveContext,
  coordinator: PermissionCoordinator,
  approvalWaiter: ApprovalWaiter,
  approvalWaitMs: number,
  config: CollavreConfig,
): Server {
  const server = new Server(
    { name: "collavre", version: "0.1.1" },
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
        'Messages from Collavre arrive as <channel source="collavre" topic_id="..." author="..." comment_id="..." task_id="..." execution_generation="...">.',
        "Reply using the reply tool, passing topic_id, task_id, AND execution_generation from the tag",
        "(task_id correlates the reply with the exact dispatched task when",
        "multiple delegated tasks can be in flight on the same topic).",
        'Never reply to your own messages (author starts with "claude-").',
        "Before doing something the human should sign off on (irreversible, out of scope, or ambiguous),",
        "ask with the approval_request tool: it posts your question with Approve/Deny buttons and waits for their decision.",
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
            execution_generation: { type: "string", description: "Echo execution_generation from the dispatch tag without changing it." },
            task_id: {
              type: "number",
              description:
                "Task ID echoed from the dispatch notification meta. Required: when topic concurrency > 1 multiple delegated tasks can coexist, and replies must correlate to the exact dispatched task — omitting this would let the server fall back to the oldest delegated task and complete the wrong one.",
            },
          },
          required: ["topic_id", "text", "task_id", "execution_generation"],
        },
      },
      {
        name: "approval_request",
        description:
          "Ask the human in Collavre to approve or deny something before you act, and wait for their answer. " +
          "The question is posted into the current topic with Approve / Deny buttons and this call blocks until " +
          "someone decides, returning approved or denied plus their optional reason and who decided. " +
          "Denial is a normal result: do not perform the denied action, reconsider the plan instead. " +
          "There is no deadline on the human — if the wait window elapses the call returns pending with a " +
          "request_id; call it again with that request_id to keep waiting, or end your turn saying you are blocked. " +
          "If you confirm the gate was deleted, pass request_id and abandon=true to release local tracking. " +
          "Abandoning does not grant approval or change a server gate.",
        inputSchema: {
          type: "object" as const,
          properties: {
            question: {
              type: "string",
              description:
                "The concrete decision you need from the human. Markdown supported. Omit when resuming or abandoning via request_id.",
            },
            approver_user_id: {
              type: "number",
              description:
                "Optional: route the decision to this Collavre user instead of the person running this session. Must be a human who can read the creative.",
            },
            abandon: {
              type: "boolean",
              description:
                "Release only this session's local wait for request_id after confirming its gate was deleted. Does not approve, deny, or delete a server gate.",
            },
            request_id: {
              type: "string",
              description:
                "Optional: keep waiting on an approval request you already raised (returned in a pending result). Omit to raise a new request.",
            },
          },
        },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    if (req.params.name === "approval_request") {
      return await runApprovalRequest(req.params.arguments, {
        relay: params => client.requestApproval(params),
        waiter: approvalWaiter,
        coordinator,
        active,
        waitMs: approvalWaitMs,
        newRequestId: () => newApprovalRequestId(randomUUID),
        log: message => process.stderr.write(`${message}\n`),
      });
    }

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

    if (typeof record.execution_generation !== "string" || !record.execution_generation) {
      return errorResult("execution_generation is required — echo it from the dispatch notification meta");
    }
    const result = await replyWithApprovalHandoff(config, topicId, text, taskId, record.execution_generation, approvalWaiter, coordinator, active).catch(async error => {
      await quotaState.prune(turn => client.quotaTurnCurrent(turn));
      throw error;
    });
    quotaState.remove(taskId, record.execution_generation);


    return {
      content: [
        { type: "text" as const, text: `Sent (comment #${result.comment_id})` },
      ],
    };
  });

  return server;
}

async function main(): Promise<void> {
  const debug = process.env.COLLAVRE_DEBUG === "1";
  const config = loadConfig();
  process.stderr.write(`[collavre] Config loaded: url=${config.url}\n`);

  const client = new CollavreClient(config);
  const agentName = config.agentName;
  // Session id is stable per working directory (S1): a --resume from the same
  // cwd re-binds to the same Collavre topic instead of orphaning a new one.
  const sessionId = resolveSessionId({
    cwd: process.cwd(),
    stateDir: defaultSessionStateDir(),
    override: config.sessionIdOverride,
  });
  process.stderr.write(
    `[collavre] Agent="${agentName}" session=${sessionId} (cwd=${process.cwd()})\n`,
  );

  const coordinator = new PermissionCoordinator();
  const approvalWaiter = new ApprovalWaiter();
  const approvalWaitMs = resolveApprovalWaitMs(process.env);
  const active: ActiveContext = {
    topicId: null,
    taskId: null,
    defaultTopicId: null,
    sessionTopicId: null,
  };
  const server = buildServer(client, active, coordinator, approvalWaiter, approvalWaitMs, config);

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
      coordinator.add(request_id);
      try {
        // Send only the structured fields; the server renders the (localized)
        // prompt text and attaches the approve/deny buttons. No client-side
        // formatting or free-text parsing. `description` is Claude Code's
        // human-readable action summary — forwarded so the approver sees the
        // same context the local TUI dialog shows when arguments are opaque.
        await client.notify(topicId, "", taskId ?? undefined, request_id, {
          toolName: tool_name,
          description,
          arguments: input_preview,
        });
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
    makeEventHandler(server, client, coordinator, approvalWaiter, active, debug, quotaState),
    debug,
  );

  // Pull-on-resubscribe: after every (re)subscribe, tell the server the
  // permission request_ids this session still holds pending so it replays any
  // decision broadcast into a subscriber-less stream while the WebSocket was
  // down. The coordinator's pending set is the source of truth — there is no
  // wall-clock window, so a decision clicked during an outage of any length is
  // redelivered once the link is back. Empty set (the common case) → no-op.
  cable.onSubscriptionConfirmed(() => {
    const pending = coordinator.pendingIds();
    if (pending.length > 0) {
      cable.perform("replay_permissions", { request_ids: pending });
    }
  });

  await cable.connect();
  process.stderr.write("[collavre] WebSocket ready\n");

  const reg = await client.register({
    agentName,
    sessionId,
    sessionLabel: basename(process.cwd()),
  });
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
  active.sessionTopicId = reg.topic_id;

  // Subscribe by agent_id, not topic_id. Comments in the registration inbox
  // are skipped by Comment#dispatch_to_orchestration; real dispatches arrive
  // on the per-agent stream regardless of which topic triggered them.
  cable.subscribeToAgent(reg.agent_id, sessionId);

  const cleanup = async () => {
    quotaState.clear();
    cable.disconnect();
    await client.unregister(reg.agent_id, reg.topic_id, sessionId);
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
