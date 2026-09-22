#!/usr/bin/env node
import { loadConfig } from "./config.js";
import { quotaFailure, type FailureInput } from "./quota-failure.js";
import { onlyQuotaTurn, quotaDirectory } from "./quota-state.js";

async function main(): Promise<void> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 65536) return;
    chunks.push(chunk);
  }
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8")) as FailureInput;
  const failure = quotaFailure(input);
  if (!failure || !input.cwd) return;
  const turn = onlyQuotaTurn(quotaDirectory(input.cwd));
  if (!turn) return;
  const config = loadConfig();
  const response = await fetch(`${config.url.replace(/\/$/, "")}/api/v1/agent/tasks/${turn.task_id}/suspend`, {
    method: "POST", signal: AbortSignal.timeout(5000),
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${config.token}` },
    body: JSON.stringify({ reason: "quota", execution_generation: turn.execution_generation, ...failure }),
  });
  if (!response.ok) process.stderr.write(`[collavre] Quota suspension rejected (${response.status})\n`);
}
main().catch(() => { process.stderr.write("[collavre] Quota suspension could not be delivered\n"); });
