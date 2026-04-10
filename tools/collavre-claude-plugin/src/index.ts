#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { hostname } from "os";
import { randomBytes } from "crypto";
import { CollavreClient } from "./collavre-client.js";
import { CableSubscriber } from "./cable-subscriber.js";
import { loadConfig } from "./config.js";

function shortId(): string {
  return randomBytes(2).toString("hex");
}

async function main(): Promise<void> {
  const DEBUG = process.env.COLLAVRE_DEBUG === "1";
  const config = loadConfig();
  process.stderr.write(`[collavre] Config loaded: url=${config.url}\n`);
  const client = new CollavreClient(config);
  const agentName = `${hostname().split(".")[0]}-${shortId()}`;

  const server = new Server(
    { name: "collavre", version: "0.1.0" },
    {
      capabilities: {
        experimental: {
          "claude/channel": {},
          "claude/channel/permission": {},
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

  // --- Tools ---

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "reply",
        description: "Send a reply message to the Collavre channel topic",
        inputSchema: {
          type: "object" as const,
          properties: {
            topic_id: {
              type: "string",
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
    if (req.params.name === "reply") {
      const args = req.params.arguments as { topic_id: string; text: string };
      const topicId = parseInt(args.topic_id, 10);
      if (isNaN(topicId)) {
        return {
          content: [{ type: "text" as const, text: "Invalid topic_id" }],
          isError: true,
        };
      }
      const result = await client.reply(topicId, args.text);
      return {
        content: [
          { type: "text" as const, text: `Sent (comment #${result.comment_id})` },
        ],
      };
    }

    return {
      content: [{ type: "text" as const, text: `Unknown tool: ${req.params.name}` }],
      isError: true,
    };
  });

  // Connect stdio transport FIRST — Claude Code sends an MCP initialize
  // request immediately after spawning this process and will timeout if
  // we block on network calls before reading stdin.
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write("[collavre] MCP server started\n");

  // Register agent — creates AI User + inbox Topic on the server
  const reg = await client.register(agentName);
  process.stderr.write(
    `[collavre] Registered: ${reg.agent_name} → topic #${reg.topic_id} (${reg.topic_name})\n`,
  );

  // Subscribe to ActionCable for orchestrated dispatch events
  const cable = new CableSubscriber(config.url, config.token, reg.topic_id, async (event) => {
    if (event.type !== "dispatch" || !event.comment) {
      if (DEBUG) process.stderr.write(`[collavre] Ignoring non-dispatch event: ${JSON.stringify(event).slice(0, 200)}\n`);
      return;
    }

    process.stderr.write(
      `[collavre] Dispatch: comment #${event.comment.id} by ${event.comment.author_name} (id=${event.comment.author_id})\n`,
    );

    const notification = {
      method: "notifications/claude/channel" as const,
      params: {
        content: event.comment.content,
        meta: {
          topic_id: String(reg.topic_id),
          comment_id: String(event.comment.id),
          author: event.comment.author_name,
          author_id: String(event.comment.author_id),
        },
      },
    };

    try {
      await server.notification(notification);
      process.stderr.write(`[collavre] Notification sent OK\n`);
    } catch (err) {
      process.stderr.write(
        `[collavre] Failed to forward message: ${err instanceof Error ? err.stack : err}\n`,
      );
    }
  }, DEBUG);
  cable.connect();

  // --- Lifecycle ---

  const cleanup = async () => {
    cable.disconnect();
    await client.unregister(reg.agent_id, reg.topic_id);
    process.exit(0);
  };

  process.on("SIGTERM", cleanup);
  process.on("SIGINT", cleanup);
}

main().catch((err) => {
  process.stderr.write(`[collavre] Fatal: ${err instanceof Error ? err.message : err}\n`);
  process.exit(1);
});
