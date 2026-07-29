# Collavre

[![CI](https://github.com/sh1nj1/plan42/actions/workflows/ci.yml/badge.svg)](https://github.com/sh1nj1/plan42/actions/workflows/ci.yml) [![codecov](https://codecov.io/gh/sh1nj1/plan42/graph/badge.svg)](https://codecov.io/gh/sh1nj1/plan42)

**One living tree for docs, tasks, discussions, and AI agent context.**

Today those are three copies you keep in sync by hand, plus an agent wired to all of them
that still has to guess which one is true. A block in Collavre is all four at once — one
object. Pin a rule at the root and every task below it inherits it, for people and agents alike.

[**Live demo**](https://collavre.com) · [**Watch the 90-second demo**](https://collavre.com/landing#demo) · [Features](docs/features_summary.md) · AGPL-3.0

---

## The problem

You write the same thing three times.

1. **The doc.** You write the spec.
2. **The tracker.** You retype it as tickets — and the link back to the paragraph it came from is never written down anywhere.
3. **The thread.** You explain it a third time in chat, where the decision scrolls away attached to nothing.

Then you bring in an agent. Nobody pastes context by hand anymore — you connect it over
MCP and it can read all three. But it reads three copies that have drifted apart, with no
record of how they relate, and no boundary telling it where this task ends. So it guesses,
from keywords, every single session.

The duplication was always waste, but people carry the missing structure in their heads,
so it stayed tolerable. An agent carries nothing between calls. That is what turns a quiet
tax into a daily one.

## How it works

**One object, not three copies.** A *block* is simultaneously a document, a task, a
discussion thread, and a unit of agent context. Blocks nest into a tree.

**Markdown in, task tree out.** Import a spec and heading depth becomes tree depth, one
to one. Nothing is retyped. Progress rolls up from leaf to root on its own.

**Context is lexically scoped.** Pin a context block at any node — coding conventions, a
design doc, deploy rules — and every descendant inherits it. Call an agent on a leaf task
three levels down and it arrives with that context already attached. From there it can
traverse the rest of the tree itself over MCP.

That last one is the whole idea: **the unit of work is the unit of agent context.** It is
lexical scoping, but for work.

## The document is the tree

A structure this good is worthless if writing in it feels like filing a ticket. So the tree
is not a list of task titles with documents hidden behind them — it *is* the document. A
heading, a paragraph, a fenced code block, a table: each is a block, rendered in place,
each carrying its own progress and its own thread.

- **Markdown-first.** Any block flips between rich text and raw markdown; markdown is what
  gets stored. Import a `.md` file by dropping it on the tree, export any subtree back out.
- **A real editor.** Fenced code with syntax highlighting (Prism), tables, images, video,
  attachments, links, colors — [Lexical](https://lexical.dev), not a textarea.
- **Drag a block and its subtree comes with it**, re-parenting included.
- **Presence.** See who is in the document and who is editing which block.

## Why not just MCP?

We ship an MCP server too, and agents search and traverse the tree through it. Still:

- **Retrieval answers *"what matches this query."* Inheritance answers *"what is always true here."*** The hard part was never reaching the data — it is knowing the boundary of the task. An agent over a flat store re-guesses that boundary from keywords every session. In a tree it does not guess; the structure already knows.
- **Connectors reconstruct at read time the relationships that were destroyed at write time.** When you retyped the spec into a ticket, the link between them was never written down. No amount of retrieval recovers a link that was never recorded.
- **A flat store has nothing to inherit.** That is the part a connector cannot add from the outside.

An MCP server over a doc store returns documents. An MCP server over a tree returns a scope.

## Quick start

Requires Ruby 3.4 (via [mise](https://mise.jdx.dev/)), Node, and libvips
(`brew install vips` on macOS).

```bash
git clone https://github.com/sh1nj1/plan42.git && cd plan42
mise install && npm ci
bin/setup            # bundle, prepare + seed the DB, then start the dev server on :3000
```

Sign in as `admin@example.com` / `password123` — set `DEFAULT_USER_EMAIL` and
`DEFAULT_USER_PASSWORD` before the first run to override.

To point an agent at it over MCP, see [docs/mcp-configuration.md](docs/mcp-configuration.md).

## What's inside

- **Rails 8**, 8 isolated engines — `collavre` is the core, and every `collavre_*` engine depends on it, never the reverse
- An **MCP server** and an **OpenAI-compatible completion API**
- **Two-way sync** with GitHub, Linear, Slack, and Notion
- **Real-time chat** on every block (ActionCable), organized into topics
- **Hierarchical permissions** backed by a materialized permission cache
- **WebAuthn** and **OAuth** authentication
- Self-hosted via Docker. **AGPL-3.0.**

## Known limits

Stated up front, because you would find them anyway:

- **No token budget yet.** How much of the subtree and chat history an agent receives is a per-agent setting (depth, message count) — not a tokenizer-aware budget.
- **"Creative" still leaks into the UI** as the internal name for a block. It is the original domain term, and the rename is not finished.
- **Import is markdown-first.** Heading depth maps cleanly onto tree depth; other structure (tables, front-matter) survives as block content but does not become tree structure.

## Development

```bash
bin/dev                                   # dev server on :3000
./script/install-hooks.sh                 # pre-push: rubocop, tests, i18n + dead-code checks
bin/rake test && bin/rails test:system    # host app + every engine
```

System tests run headless by default; `SYSTEM_TEST_DRIVER=chrome bin/rails test:system`
to watch them in a real browser.

JavaScript is bundled with `jsbundling-rails`, so `npm ci` must run before
`rails assets:precompile` in any production build. The provided `Dockerfile` and
`render.yaml` both do this.

## More

- [Engine development guide](docs/engine_development.md) — Collavre is extended with local Rails engines
- [Deploy to AWS Lightsail](docs/deploy_to_lightsail.md) — app + PostgreSQL on one instance
- [Deploy to AWS EC2](docs/deploy_to_ec2.md)
- [MCP configuration](docs/mcp-configuration.md)

## License

Collavre is distributed under the terms of the
[GNU Affero General Public License v3.0](LICENSE).
