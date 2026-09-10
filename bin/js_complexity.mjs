#!/usr/bin/env node
// JavaScript measurement for the complexity ratchet. Prints
// {"path | rule | entity": value} as JSON on stdout; bin/complexity_check
// merges it with the Ruby measurement and does the comparing.
//
//   node bin/js_complexity.mjs --root . --config .eslint_metrics.yml
//
// --root is the tree to measure, which for the base side of the ratchet is a
// detached worktree with no node_modules of its own. Nothing is resolved out of
// it: the rules come from --config and ESLint comes from this script's own
// node_modules, so both sides are measured with this branch's budget.
import path from "node:path";

import { loadBudget, measure } from "../lib/js_complexity/measure.js";

function parseArgv(argv) {
  const options = { root: process.cwd(), config: ".eslint_metrics.yml" };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === "--root" || flag === "--config") {
      const value = argv[i + 1];
      if (value === undefined) throw new Error(`${flag} needs a value`);
      options[flag.slice(2)] = value;
      i += 1;
    } else if (flag === "-h" || flag === "--help") {
      options.help = true;
    } else {
      throw new Error(`unknown option ${flag}`);
    }
  }
  return options;
}

const options = parseArgv(process.argv.slice(2));

if (options.help) {
  console.log("Usage: node bin/js_complexity.mjs [--root DIR] [--config FILE]");
  process.exit(0);
}

const budget = loadBudget(path.resolve(options.config));
const measured = await measure({ root: path.resolve(options.root), budget });

process.stdout.write(`${JSON.stringify(measured, null, 2)}\n`);
