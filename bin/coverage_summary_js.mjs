#!/usr/bin/env node
// Render a GitHub-flavoured Markdown coverage summary from Jest's json-summary
// report. Written for GitHub Actions job summaries:
//
//   node bin/coverage_summary_js.mjs coverage/js/coverage-summary.json >> "$GITHUB_STEP_SUMMARY"
//
// Exits 0 with a friendly note if the report is missing so a coverage-less run
// never fails the job on the summary step alone.
import { readFileSync } from "node:fs";

const path = process.argv[2] || "coverage/js/coverage-summary.json";

const header = "## 🟨 JavaScript coverage (Jest)";

let data;
try {
  data = JSON.parse(readFileSync(path, "utf8"));
} catch {
  console.log(`${header}\n\n_No coverage summary found at \`${path}\`._`);
  process.exit(0);
}

const t = data.total;
if (!t) {
  console.log(`${header}\n\n_Coverage summary at \`${path}\` had no totals._`);
  process.exit(0);
}

const row = (label, m) =>
  `| ${label} | ${m.pct.toFixed(2)}% | ${m.covered}/${m.total} |`;

const lines = [
  header,
  "",
  `**Line: ${t.lines.pct.toFixed(2)}%** (${t.lines.covered}/${t.lines.total})`,
  "",
  "| Metric | Coverage | Covered/Total |",
  "|---|---|---|",
  row("Lines", t.lines),
  row("Statements", t.statements),
  row("Branches", t.branches),
  row("Functions", t.functions),
  "",
  "_`.jsx` React components are excluded (no JSX-aware coverage transform is registered — see jest.config.cjs)._",
];

console.log(lines.join("\n"));
