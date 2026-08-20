---
name: collavre
description: Manage Collavre Creatives (hierarchical tasks/content blocks) via CLI. Use when creating, retrieving, updating, importing, or batch-operating on Creatives. Creatives are tree-structured items with automatic progress rollup — like a smart to-do list that doubles as a structured document.
---

# Collavre

CLI for managing Collavre Creatives via MCP protocol.

## Setup

```bash
# Configure (once)
collavre auth --url https://collavre.example.com --token <oauth_token>

# Verify
collavre list
```

The `collavre` script lives in `scripts/collavre`. Config is stored at `~/.config/collavre/config.json`.

## Commands

### List root creatives
```bash
collavre list
collavre list --level 5              # deeper tree
collavre list --format json          # structured output
```

### Get a creative subtree
```bash
collavre get 123
collavre get 123 --level 5 --comments
```

### Search
```bash
collavre search "project name"
collavre search "urgent" --tags "v2"
```

### Create
```bash
collavre create --parent 123 --desc "New task"
collavre create --parent 123 --desc "# Rich content\n\n- point one\n- point two"
```

### Update
```bash
collavre update 456 --desc "Updated title"
collavre update 456 --progress 1.0        # mark complete (leaf only)
collavre update 456 --parent 789           # move
```

### Import markdown
```bash
collavre import --parent 123 --file plan.md
collavre import --parent 123 --stdin < plan.md
echo "# Quick\n## Plan" | collavre import --parent 123 --stdin
```

### Attach a file
```bash
collavre attach --creative 123 --file ./hero.png    # png/mp4/pdf/svg
```
Uploads the raw bytes over a bearer multipart endpoint, embeds the matching
node (`<img>`/`<video>`/`<a>`) into the creative's description, and attaches the
blob to `creative.files`. Use this for binary files on disk. For inline
agent-generated text (markdown/html/svg source), use the
`creative_attach_files_service` tool with `files: [{ filename, content }]`.

### Batch operations
```bash
collavre batch --file ops.json
```

ops.json format:
```json
[
  { "action": "create", "parent_id": 100, "description": "Task A" },
  { "action": "update", "id": 200, "progress": 1.0 },
  { "action": "delete", "id": 300 }
]
```

### Topics and messages

Topics are conversation threads on a Creative — and the unit of agent
concurrency. Tasks in the same topic are serialized (one runs, the rest queue);
tasks in different topics run in parallel. There is no dedicated CLI verb yet;
drive them through `collavre tool run`:

```bash
# See what topics exist and how much conversation each holds
collavre tool run topic_list --json '{"creative_id": 8849}'

# Summarize three topics at once — first page only; offset/limit apply per topic
collavre tool run topic_messages --json '{"topic_ids": "12,45,78", "limit": 100}'

# Continue each topic separately with its own cursor and snapshot id
collavre tool run topic_messages --json '{"topic_ids": 12, "offset": 100, "cursor": "1770000000000000:989:1770000001000000", "max_message_id": 9931}'

# Continue inside one clipped message, preserving its row cursor
collavre tool run topic_messages --json '{"topic_ids": 12, "offset": 100, "cursor": "1770000000000000:989:1770000001000000", "content_offset": 28400, "max_message_id": 9931}'

# Fan work out: one topic per unit of work, with an agent pinned to each
collavre tool run topic_create --json '{"creative_id": 8849, "name": "Research", "primary_agent": "Dev1Claude"}'

# Put a finished thread away (messages are kept and stay readable by id)
collavre tool run topic_update --json '{"topic_id": 12, "archived": true}'

# Carry the messages that still matter into a fresh topic
collavre tool run topic_branch --json '{"source_topic_id": 12, "comment_ids": "991,994"}'
```

`topic_messages` includes each comment image as a URL-bearing marker in the
message content. Image-only comments are not blank, and a long attachment list
uses the same `content_offset` continuation as long prose.

### Discover & run tools (meta)
```bash
collavre tool list                                # list available tools
collavre tool list --full                         # list with full details
collavre tool search "github"                     # search by name/description
collavre tool info <tool_name>                    # show tool parameters
collavre tool run <tool_name> --json '{"k":"v"}'  # run with JSON args
collavre tool run <tool_name> --key value         # run with flag args
```

## Key Concepts

- **Tree structure**: Creatives nest via `parent_id`. Use `--level` to control depth.
- **Topics**: conversation threads on a Creative, and the concurrency unit — same
  topic serializes, different topics run in parallel. One topic = one thread
  reaching one conclusion; archive it when it gets there rather than reusing it.
- **Primary agent**: pinning an agent to a topic is exclusive — that agent alone
  answers there. Use it for a dedicated 1:1 channel; leave it unset for a thread
  several participants should hear.
- **Progress**: Leaf = manual (0.0 or 1.0). Parent = auto-calculated from children.
- **Import**: Markdown headings/bullets become nested Creatives.
- **Batch**: All-or-nothing transaction. Requires approval.
- **Description format**: Written as Markdown (GitHub-Flavored: headings, bold/italic, lists, links, tables, code blocks, task lists). A single newline is a line break. Plain text is stored as-is.

For detailed MCP tool parameters, see [references/tool-reference.md](references/tool-reference.md).
