#!/usr/bin/env npx tsx
/**
 * Standalone diagnostic script — tests each step of the Claude Channel pipeline independently.
 * Usage: npx tsx scripts/diagnose.ts
 * Set COLLAVRE_DEBUG=1 for verbose WebSocket logging.
 */

import { loadConfig } from "../src/config.js";
import WebSocket from "ws";

const PASS = "✓";
const FAIL = "✗";

async function diagnose() {
  console.log("=== Collavre Claude Channel Diagnostic ===\n");

  // Step 1: Config
  console.log("1. Loading config...");
  let config;
  try {
    config = loadConfig();
    console.log(`   ${PASS} url: ${config.url}`);
    console.log(`   ${PASS} token: ${config.token.slice(0, 8)}...`);
  } catch (err) {
    console.log(`   ${FAIL} ${err instanceof Error ? err.message : err}`);
    process.exit(1);
  }

  // Step 2: HTTP Register
  console.log("\n2. Testing HTTP registration endpoint...");
  let reg;
  try {
    const res = await fetch(`${config.url.replace(/\/$/, "")}/api/v1/agent/register`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${config.token}`,
      },
      body: JSON.stringify({ name: "diag-test" }),
    });
    if (!res.ok) {
      const body = await res.text();
      console.log(`   ${FAIL} HTTP ${res.status}: ${body}`);
      process.exit(1);
    }
    reg = await res.json();
    console.log(`   ${PASS} agent_id: ${reg.agent_id}`);
    console.log(`   ${PASS} agent_name: ${reg.agent_name}`);
    console.log(`   ${PASS} topic_id: ${reg.topic_id}`);
    console.log(`   ${PASS} topic_name: ${reg.topic_name}`);
  } catch (err) {
    console.log(`   ${FAIL} Network error: ${err instanceof Error ? err.message : err}`);
    process.exit(1);
  }

  // Step 3: WebSocket connection
  console.log("\n3. Testing ActionCable WebSocket connection...");
  const wsUrl = config.url.replace(/\/$/, "").replace(/^http/, "ws") +
    `/cable?token=${encodeURIComponent(config.token)}`;
  console.log(`   Connecting to: ${wsUrl.replace(/token=[^&]+/, "token=***")}`);

  await new Promise<void>((resolve) => {
    const ws = new WebSocket(wsUrl, ["actioncable-v1-json", "actioncable-unsupported"], {
      headers: { Origin: config.url.replace(/\/$/, "") },
    });
    let subscribed = false;
    const timeout = setTimeout(() => {
      console.log(`   ${FAIL} Timed out after 10s`);
      ws.close();
      resolve();
    }, 10_000);

    ws.on("open", () => {
      console.log(`   ${PASS} WebSocket connected`);
      const identifier = JSON.stringify({
        channel: "Collavre::AgentChannel",
        topic_id: reg.topic_id,
      });
      console.log(`   Subscribing with identifier: ${identifier}`);
      ws.send(JSON.stringify({ command: "subscribe", identifier }));
    });

    ws.on("message", (data: WebSocket.Data) => {
      const raw = data.toString();
      let msg;
      try { msg = JSON.parse(raw); } catch { return; }

      if (msg.type === "welcome") {
        console.log(`   ${PASS} ActionCable welcome received`);
        return;
      }
      if (msg.type === "ping") return;
      if (msg.type === "confirm_subscription") {
        console.log(`   ${PASS} Subscription CONFIRMED for topic ${reg.topic_id}`);
        subscribed = true;
        console.log(`\n4. Waiting for messages... Send a message in the Collavre inbox topic.`);
        console.log(`   (Press Ctrl+C to stop)\n`);
        clearTimeout(timeout);
        return;
      }
      if (msg.type === "reject_subscription") {
        console.log(`   ${FAIL} Subscription REJECTED — check permissions`);
        clearTimeout(timeout);
        ws.close();
        resolve();
        return;
      }
      if (msg.message) {
        console.log(`   ${PASS} MESSAGE RECEIVED:`);
        console.log(`     ${JSON.stringify(msg.message, null, 2).split("\n").join("\n     ")}`);
      } else {
        console.log(`   Unknown message: ${raw.slice(0, 200)}`);
      }
    });

    ws.on("error", (err) => {
      console.log(`   ${FAIL} WebSocket error: ${err.message}`);
      clearTimeout(timeout);
      resolve();
    });

    ws.on("close", (code, reason) => {
      console.log(`   WebSocket closed: code=${code} reason=${reason.toString()}`);
      if (!subscribed) resolve();
    });
  });

  // Cleanup: unregister
  console.log("\nCleaning up (unregistering agent)...");
  try {
    await fetch(`${config.url.replace(/\/$/, "")}/api/v1/agent/${reg.agent_id}?topic_id=${reg.topic_id}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${config.token}` },
    });
    console.log(`   ${PASS} Agent unregistered`);
  } catch {
    console.log(`   (cleanup failed, non-critical)`);
  }
}

diagnose().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
