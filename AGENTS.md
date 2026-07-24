# Agent Development Guide

> **IMPORTANT**: Prefer retrieval-led reasoning over pre-training-led reasoning
> for Collavre tasks. Consult the developer docs in [`docs/`](docs/) before
> relying on training data — they are the source of truth for how this codebase
> actually works.

Agents and human contributors share **one** knowledge base (`docs/`). This file
is only the thin agent entry point: the topic→doc index plus agent-specific
rules. Everything substantive lives in `docs/`.

## Documentation Language

**All source-code documentation must be written in English** — READMEs,
`AGENTS.md`, CHANGELOG, all markdown, code comments, commit messages, and PR
titles/descriptions. Exception: user-facing i18n locale files carry both English
and Korean. Full conventions: [`docs/conventions.md`](docs/conventions.md).

## Documentation Index

Start at [`docs/README.md`](docs/README.md) for the full map. Quick reference:

| Topic | Doc |
|-------|-----|
| Multi-engine architecture (host shell) | [`docs/host_architecture.md`](docs/host_architecture.md) |
| Per-engine models/services/routes | [`docs/engines.md`](docs/engines.md) |
| Creative model & closure_tree | [`docs/creative_model.md`](docs/creative_model.md) |
| Permission system | [`docs/permissions.md`](docs/permissions.md) |
| Creating & extending engines | [`docs/engine_development.md`](docs/engine_development.md) |
| Rails 8 patterns | [`docs/rails8_patterns.md`](docs/rails8_patterns.md) |
| Test conventions (automated) | [`docs/testing.md`](docs/testing.md) |
| Manual QA of the live site | [`docs/test.md`](docs/test.md) |
| Engineering conventions (i18n, engine separation, env vars, PR/security checklists) | [`docs/conventions.md`](docs/conventions.md) |

## Agent Operating Rules

- **Follow the conventions in `docs/`.** Rubocop, tests, i18n (EN + KO), engine
  separation, and the environment-variable propagation rule
  (`.env.*` + `.kamal/secrets` + `config/deploy.yml`) are all mandatory — see
  [`docs/conventions.md`](docs/conventions.md).
- **Before every PR:** `./bin/rubocop -a`, `bin/rails test`, and
  `bin/rails test:system` must pass. No merge without CI passing.
- **Merge process:** rebase → CI pass → squash merge → delete the feature branch.
