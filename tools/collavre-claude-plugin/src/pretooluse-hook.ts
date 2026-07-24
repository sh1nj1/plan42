#!/usr/bin/env node
// PreToolUse hook entry: reads the harness hook payload on stdin and, for the
// Collavre channel `reply` tool only, prints an "allow" decision so the channel
// can answer without a permission prompt. For any other tool it prints nothing
// and exits 0, leaving the normal permission flow untouched. See hook-decision.ts.

import { decidePreToolUse, type PreToolUseInput } from "./hook-decision.js";

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString("utf8").trim();
}

async function main(): Promise<void> {
  const raw = await readStdin();
  let input: PreToolUseInput = {};
  if (raw) {
    try {
      input = JSON.parse(raw) as PreToolUseInput;
    } catch {
      input = {};
    }
  }
  const decision = decidePreToolUse(input);
  if (decision) {
    process.stdout.write(JSON.stringify(decision));
  }
  process.exit(0);
}

main().catch(() => process.exit(0));
