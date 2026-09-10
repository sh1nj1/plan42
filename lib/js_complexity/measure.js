// The JavaScript half of the complexity ratchet: runs ESLint's size and
// complexity rules over a tree and folds the offenses into
// {entity key => measured value}, the same shape ComplexityRatchet::Measurement
// produces for Ruby. bin/complexity_check merges the two and compares them
// against the merge base entity by entity.
//
// Why ESLint's Linter rather than the ESLint class: the ratchet measures a
// detached checkout of the merge base, which has no node_modules and no
// eslint.config file of its own. `Linter#verify` takes the config as a value,
// so nothing is resolved from the tree being measured — this branch's budget is
// applied to both sides, which is exactly the rule the Ruby half follows.
//
// The budget lives in .eslint_metrics.yml and holds ONLY numbers. Rule options
// that are not thresholds (skipBlankLines, IIFEs) are fixed here on purpose:
// a budget file that could carry arbitrary rule options would carry the
// bypasses with them — `max-lines: { max: 300 }` next to an `overrides` entry
// that silences a directory reads as a budget and acts as an exemption.

import { readFileSync } from "node:fs";
import path from "node:path";

import { Linter } from "eslint";
import { glob } from "glob";
import yaml from "js-yaml";

import { EntityMap } from "./entity_map.js";

// scope: how an offense maps back to an entity.
//   file      — the offense is about the whole file (max-lines reports on the
//               first line past the limit, which belongs to no entity).
//   function  — the offense is about a definition; the innermost scope
//               containing it is that definition.
//   statement — the offense is about a statement inside a definition, so it
//               falls back to "enclosing scope + source line".
export const RULES = {
  complexity: {
    scope: "function",
    options: (max) => ["error", max],
    value: /has a complexity of (\d+)\. Maximum/,
  },
  "max-depth": {
    scope: "statement",
    options: (max) => ["error", max],
    value: /\((\d+)\)\. Maximum/,
  },
  "max-lines": {
    scope: "file",
    // Blank lines and comments are skipped to match RuboCop's Metrics counters,
    // which ignore both. Otherwise the same file measures differently on the
    // two sides of the ratchet and a comment block reads as growth.
    options: (max) => ["error", { max, skipBlankLines: true, skipComments: true }],
    value: /\((\d+)\)\. Maximum/,
  },
  "max-lines-per-function": {
    scope: "function",
    options: (max) => ["error", { max, skipBlankLines: true, skipComments: true, IIFEs: true }],
    value: /\((\d+)\)\. Maximum/,
  },
  "max-nested-callbacks": {
    scope: "function",
    options: (max) => ["error", max],
    value: /\((\d+)\)\. Maximum/,
  },
  "max-params": {
    scope: "function",
    options: (max) => ["error", max],
    value: /\((\d+)\)\. Maximum/,
  },
};

export const SEPARATOR = " | ";

// The entity name used for a file-scoped offense. Parenthesised so it cannot
// collide with a real identifier.
export const FILE_ENTITY = "(file)";

export class BudgetError extends Error {}

export function parseBudget(text) {
  const budget = yaml.load(text) ?? {};
  const rules = budget.rules ?? {};
  const unknown = Object.keys(rules).filter((rule) => !(rule in RULES));
  if (unknown.length > 0) {
    throw new BudgetError(
      `.eslint_metrics.yml enables rules this tool has no entity mapping for: ${unknown.join(", ")}. ` +
        "Add them to RULES in lib/js_complexity/measure.js first."
    );
  }
  const bad = Object.entries(rules).filter(([, max]) => !Number.isInteger(max) || max < 0);
  if (bad.length > 0) {
    throw new BudgetError(
      `.eslint_metrics.yml thresholds must be non-negative integers: ${bad.map(([rule]) => rule).join(", ")}`
    );
  }

  return {
    include: budget.include ?? [],
    exclude: budget.exclude ?? [],
    rules,
  };
}

export function eslintConfig(budget) {
  return {
    files: ["**/*.js", "**/*.jsx"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    // A file that turns the budget off with an inline comment is the bypass
    // this gate exists to prevent, so directives are not honoured.
    linterOptions: { noInlineConfig: true, reportUnusedDisableDirectives: "off" },
    rules: Object.fromEntries(
      Object.entries(budget.rules).map(([rule, max]) => [rule, RULES[rule].options(max)])
    ),
  };
}

// Exported for the unit tests: the fold from ESLint messages to ratchet keys is
// where the entity naming rules live, and it is worth testing without a lint.
export function foldMessages(relativePath, source, ast, messages) {
  // A syntax error is worth crashing on: a file that silently fails to parse
  // measures as zero offenses, which reads as "clean" rather than "unread".
  // ESLint also hands back no SourceCode at all in that case, so this has to
  // come before the entity map is built.
  const fatal = messages.find((message) => message.fatal);
  if (fatal) {
    throw new Error(`${relativePath}:${fatal.line ?? "?"} could not be parsed: ${fatal.message}`);
  }

  const entities = EntityMap.for(ast, source);
  const measured = {};

  for (const message of messages) {
    // Rule-less, non-fatal messages are ESLint talking about itself — the one
    // this config produces is the notice that an `eslint-disable-line` comment
    // had no effect under noInlineConfig, which is the intended outcome.
    if (!message.ruleId) continue;

    const rule = RULES[message.ruleId];
    if (!rule) throw new Error(`unexpected rule ${message.ruleId} in ${relativePath}`);

    const name = entityName(rule.scope, entities, message);
    const key = [relativePath, message.ruleId, name].join(SEPARATOR);
    const value = extractValue(rule, message, relativePath);
    measured[key] = Math.max(measured[key] ?? 0, value);
  }

  return measured;
}

function entityName(scope, entities, message) {
  if (scope === "file") return FILE_ENTITY;
  if (scope === "statement") return entities.fallbackAt(message.line, message.column);

  return entities.nameAt(message.line, message.column) ?? FILE_ENTITY;
}

function extractValue(rule, message, relativePath) {
  const match = rule.value.exec(message.message);
  // Silently counting an unreadable message as 1 would turn a rule whose
  // wording changed in an ESLint upgrade into an entity that can never grow.
  if (!match) {
    throw new Error(`cannot read a measured value out of "${message.message}" (${relativePath})`);
  }
  return Number(match[1]);
}

export async function measure({ root, budget }) {
  const files = await glob(budget.include, {
    cwd: root,
    ignore: budget.exclude,
    nodir: true,
    posix: true,
    dot: false,
  });

  const linter = new Linter();
  const config = eslintConfig(budget);
  const measured = {};

  for (const relativePath of files.sort()) {
    const source = readFileSync(path.join(root, relativePath), "utf8");
    const messages = linter.verify(source, config, relativePath);
    if (messages.length === 0) continue;

    Object.assign(measured, foldMessages(relativePath, source, linter.getSourceCode()?.ast, messages));
  }

  return measured;
}

export function loadBudget(configPath) {
  return parseBudget(readFileSync(configPath, "utf8"));
}
