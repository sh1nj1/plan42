#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { hostname } from "os";
import { CollavreClient } from "./collavre-client.js";
import { CableSubscriber, type AgentEvent } from "./cable-subscriber.js";
import { loadConfig } from "./config.js";

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

function buildServer(client: CollavreClient): Server {
  const server = new Server(
    { name: "collavre", version: "0.1.0" },
    {
      capabilities: {
        experimental: {
          "claude/channel": {},
        },
        tools: {},
      },
      instructions: [
        'Messages from Collavre arrive as <channel source="collavre" topic_id="..." author="..." comment_id="...">.',
        "Reply using the reply tool, passing topic_id from the tag.",
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
          },
          required: ["topic_id", "text"],
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

    const result = await client.reply(topicId, text);
    return {
      content: [
        { type: "text" as const, text: `Sent (comment #${result.comment_id})` },
      ],
    };
  });

  return server;
}

function makeEventHandler(server: Server, debug: boolean) {
  return async (event: AgentEvent): Promise<void> => {
    if (event.type !== "dispatch" || !event.comment) {
      if (debug) {
        process.stderr.write(
          `[collavre] Ignoring non-dispatch event: ${JSON.stringify(event).slice(0, 200)}\n`,
        );
      }
      return;
    }

    process.stderr.write(
      `[collavre] Dispatch: comment #${event.comment.id} by ${event.comment.author_name} (id=${event.comment.author_id})\n`,
    );

    try {
      await server.notification({
        method: "notifications/claude/channel" as const,
        params: {
          content: event.comment.content,
          meta: {
            topic_id: String(event.comment.topic_id),
            comment_id: String(event.comment.id),
            author: event.comment.author_name,
            author_id: String(event.comment.author_id),
          },
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
  const server = buildServer(client);

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
    makeEventHandler(server, debug),
    debug,
  );
  await cable.connect();
  process.stderr.write("[collavre] WebSocket ready\n");

  const reg = await client.register(agentName);
  process.stderr.write(
    `[collavre] Registered: ${reg.agent_name} → topic #${reg.topic_id} (${reg.topic_name})\n`,
  );

  cable.subscribeTo(reg.topic_id);

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
