# Collavre Claude Code Plugin

Connects a running **Claude Code** session to a **[Collavre](https://collavre.com)** inbox so the
two can talk in real time. Comments you post on a Collavre topic arrive in the live Claude Code
session, and Claude answers back into the same topic — without you switching windows.

It is an **MCP stdio plugin** that registers Claude Code as a Collavre *agent* and subscribes to a
*channel* over WebSocket. Mid-turn tool-permission prompts (e.g. "allow this file write?") are also
relayed to the topic, so you can `allow` / `deny` them by replying from Collavre.

---

## For users — applying this plugin to Claude Code

### What you get

- **Two-way chat**: post a comment on a Collavre topic → it lands in the Claude Code session as a
  channel message; Claude replies into the topic with the `reply` tool.
- **Remote permission approvals**: when Claude hits a tool that needs permission, a `🔐 permission
  request` is posted to the topic. Reply `allow` or `deny` to decide it remotely.
- **Agent / Session model** (see below): by default all your sessions show up under a single
  `claude` agent, each session mapped to its own topic.

### Prerequisites

- Claude Code **v2.1.168+** (native channel + permission relay).
- A Collavre server URL and an API **token**.

### Install (recommended: via the marketplace)

```bash
# 1. Register this repo as a plugin marketplace
claude plugin marketplace add sh1nj1/plan42

# 2. Install the plugin
claude plugin install collavre@collavre
```

Then provide config when prompted (or via env): the **server URL** and the **API token**.

### Install (alternative: register the MCP server directly)

If you are running from a checkout instead of the marketplace:

```bash
claude mcp add --scope local collavre -- \
  node /absolute/path/to/tools/collavre-claude-plugin/dist/index.js
```

> ⚠️ **Gotcha:** `--plugin-dir` alone does **not** wire up the channel. Claude Code only routes
> channel/permission notifications to MCP servers registered in a real scope
> (`enterprise` / `user` / `project` / `local`). Use `claude plugin install` or
> `claude mcp add --scope local` so the server is discoverable as `server:collavre`.

### Configuration

| Option | Env var | Required | Default | Meaning |
|--------|---------|----------|---------|---------|
| `url` | `CLAUDE_PLUGIN_OPTION_url` | ✅ | — | Collavre server URL, e.g. `https://collavre.com` |
| `token` | `CLAUDE_PLUGIN_OPTION_token` | ✅ | — | Collavre API token (sensitive) |
| `agent_name` | `CLAUDE_PLUGIN_OPTION_agent_name` | — | `claude` | The user-facing **agent** identity |
| `session_id` | `CLAUDE_PLUGIN_OPTION_session_id` | — | derived per-cwd | Pin a specific **session** id by hand |

Without env vars, config falls back to `~/.config/collavre/config.json`:

```json
{ "url": "https://collavre.com", "token": "..." }
```

### Agent vs. Session — how identity maps to Collavre

- **Agent** is the unit *you* care about. Most people treat Claude as a single assistant, so when
  you don't set `agent_name`, every session collapses onto one shared `claude` agent (one Collavre
  agent per human). Set a distinct `agent_name` to carve out a separate agent.
- **Session** maps a single Claude Code session to one Collavre **topic**. The session id is
  **derived from and persisted per working directory** (under `~/.config/collavre/sessions`), so
  stopping a session and later `--resume`/`--continue` from the same directory re-attaches to the
  **same topic** instead of orphaning it. (The process id is deliberately not used — it changes on
  every restart.)

So: one agent, many session-topics fanned out under it. Ending one session does not disturb a
sibling session that is still live under the same agent.

### Trying it locally

1. Point `url` at your preview/server and make sure its DB schema is current.
2. Start a Claude Code session with the plugin registered (above).
3. Post a comment on the agent's inbox topic in Collavre → watch it arrive in the session.
4. To exercise multi-session, run two Claude Code sessions from **different directories** with the
   same token and the same (default) `agent_name`: each gets its own topic under the one agent.

---

## For developers — working on this plugin

### Layout

```
tools/collavre-claude-plugin/
├── .claude-plugin/plugin.json   # Claude Code plugin manifest (channels, hooks, userConfig)
├── .mcp.json                    # MCP stdio server entry (node dist/index.js)
├── hooks/hooks.json             # SessionStart hook: auto npm install + build
├── src/
│   ├── index.ts                 # MCP server: tools (`reply`), channel + permission wiring
│   ├── config.ts                # config + agent-name / session-id resolution
│   ├── session.ts               # S1: stable, cwd-persisted session id
│   ├── collavre-client.ts       # HTTP client (register / unregister / reply)
│   ├── cable-subscriber.ts      # ActionCable WebSocket subscriber
│   ├── dispatch-filter.ts       # sibling-session dispatch filtering
│   ├── permission.ts            # native permission-relay coordinator
│   └── *.test.ts                # node:test unit tests
└── scripts/diagnose.ts          # standalone pipeline diagnostic
```

### Build & test

```bash
npm install        # deps (the SessionStart hook also does this automatically)
npm run build      # tsc -> dist/  (dist/ is gitignored; built on demand)
npm run dev        # tsc --watch
npm test           # node --test on src/**/*.test.ts
```

> Tests follow **TDD** (RED → GREEN). Add a failing `*.test.ts` next to the module first, then
> implement. Pure decision logic (agent-name resolution, register body, dispatch filter, session
> id) is factored out so it is testable without a live WebSocket.

### Diagnosing the pipeline

```bash
COLLAVRE_DEBUG=1 npx tsx scripts/diagnose.ts
```

Walks the four stages independently — **config → register → WebSocket connect → message receipt** —
and prints a ✓/✗ per step. Use this first when "collavre: failed" appears; the most common cause is
a server running an out-of-date DB schema (restart the server after migrating).

### How it works (request flow)

1. **Register** (`collavre-client.ts`): `POST` agent registration with `{ agent_name, session_id }`.
   The server keys an agent (ai_user) by `agent_name` and a topic by `session_id`.
2. **Subscribe** (`cable-subscriber.ts`): open the ActionCable channel for the agent; the
   subscribe identifier carries the `session_id` so the server can stamp the presence row.
3. **Dispatch** (`index.ts` + `dispatch-filter.ts`): incoming comments arrive as
   `<channel source="collavre" topic_id="..." task_id="..." .../>`. `shouldHandleDispatch` ignores
   sibling session topics so only the owning session answers.
4. **Reply** (`reply` tool): Claude calls `reply(topic_id, text, task_id)` to post back.
5. **Permissions** (`permission.ts`): when CC relays `permission_request`, a coordinator parks it,
   posts a prompt to the topic, and resolves on the `allow`/`deny` reply.

### Releasing

Bump `version` in **both** `package.json` and `.claude-plugin/plugin.json`, and the plugin entry in
the repo-root `.claude-plugin/marketplace.json`. `dist/` is built on demand (gitignored), so there
is nothing to commit there.
