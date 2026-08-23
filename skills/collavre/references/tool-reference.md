# Collavre MCP Tool Reference

## creative_retrieval_service

Retrieve Creatives by ID, search query, or list roots.

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `id` | Integer | No | — | Specific Creative ID (returns subtree) |
| `query` | String | No | — | Text search in descriptions and comments |
| `level` | Integer | No | 3 | Tree depth to return |
| `tags` | String | No | — | Comma-separated tag filter |
| `progress_min` | Float | No | — | Min progress (0.0–1.0) |
| `progress_max` | Float | No | — | Max progress (0.0–1.0) |
| `updated_since` | String | No | — | ISO8601 timestamp |
| `include_comments` | Boolean | No | false | Include recent comments (up to 3 per Creative) |
| `format` | String | No | "markdown" | "markdown" or "json" |

**Markdown output format:**
```
<!-- format: [id] description (progress%) -->
- [123] My Task (50%)
  - [124] Subtask A (100%)
  - [125] Subtask B (0%)
```

**JSON output** includes: `id`, `description`, `progress`, `parent_id`, `tags`, `linked`, `origin_id`, `has_children`, `children_count`, `created_at`, `updated_at`, `children[]`, and optionally `recent_comments[]`.

## creative_create_service

Create a new Creative.

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `description` | String | **Yes** | — | Content/title, written as Markdown (GFM) |
| `parent_id` | Integer | No | — | Parent Creative ID (omit for root) |
| `progress` | Float | No | 0 | Initial progress (0.0–1.0) |
| `after_id` | Integer | No | — | Sibling ID to insert after |
| `before_id` | Integer | No | — | Sibling ID to insert before |

**Returns:** `{ success, id, description, parent_id, progress }` or `{ error, details }`

## creative_update_service

Update an existing Creative.

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `id` | Integer | **Yes** | — | Creative ID to update |
| `description` | String | No | — | New content/title, written as Markdown (GFM); replaces the whole body |
| `progress` | Float | No | — | Only `1.0` allowed; leaf Creatives only |
| `parent_id` | Integer | No | — | New parent ID (0 = make root) |

**Constraints:**
- Progress: only `1.0` accepted (mark complete). No partial progress.
- Only leaf Creatives (no children) can have progress set directly.
- Parent progress auto-calculates from children.
- Circular parent references are rejected.

## creative_batch_service

Execute multiple operations atomically. **Requires approval.**

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `operations` | Array | **Yes** | Array of operation objects |

**Operation formats:**

| Action | Fields |
|--------|--------|
| `create` | `action`, `description`, `parent_id`, `progress`, `after_id`, `before_id` |
| `update` | `action`, `id`, `description`, `progress`, `parent_id` |
| `delete` | `action`, `id` |

**Behavior:** All-or-nothing transaction. If any operation fails, everything rolls back.

**Returns:** `{ success, results[] }` or `{ success: false, error, results[] }`

## creative_import_service

Import a markdown document as a Creative tree. Uses the built-in MarkdownImporter which supports headings, bullet lists, tables, fenced code blocks, and inline images. **Requires approval.**

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `markdown` | String | **Yes** | Markdown text to import |
| `parent_id` | Integer | **Yes** | Parent Creative ID to import under |

**Supported markdown elements:**
- Headings (`#` through `######`) → nested Creatives by level
- Bullet lists (`-`, `*`, `+`) → nested children by indent
- Tables → single Creative with HTML table
- Fenced code blocks (`` ``` ``) → single Creative with `<pre><code>`
- Inline images and links → preserved in description HTML

**Returns:** `{ success, parent_id, created_count, tree[] }`

## Topic tools

A **topic** is a conversation thread on a Creative, and it is also the unit of
agent concurrency: tasks dispatched in the same topic are serialized (one holds
the topic's slot, the rest queue), while tasks in different topics run in
parallel. Splitting work across topics is what makes it run concurrently.

### topic_list

List a Creative's topics, or describe specific topics by id. The planning call —
use it before `topic_messages` to see how much conversation each topic holds.

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `creative_id` | Integer | One of | — | List every topic on this Creative |
| `topic_ids` | String | One of | — | Describe these topics, e.g. `"12,45,78"` (max 20 per call) |
| `include_archived` | Boolean | No | false | Include archived topics (listing by `creative_id`) |
| `include_stats` | Boolean | No | true | Include `message_count` / `message_chars` / `last_message_at` |
| `include_system` | Boolean | No | false | Count authorless notices. Approval prompts are never counted |

**Returns:** `{ topics[], errors[] }`. Each topic: `id`, `name`, `creative_id`,
`archived`, `main`, `system`, `source_topic_id`, `primary_agent`,
`agent_locked`, `message_count`, `message_chars`, `last_message_at`.

`message_chars` combines stored message HTML length with a conservative estimate
for the image attachment markers emitted by `topic_messages`. It is good for
relative sizing rather than exact budgeting. Requires **read** on each topic's
Creative; unknown or unreadable ids come back in `errors`.

### topic_messages

Read messages from one or more topics, newest first, with paging.

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `topic_ids` | String | **Yes** | — | `"12,45,78"` (max 20 per call); a single id also works |
| `offset` | Integer | No | 0 | Messages back from the newest, **per topic** |
| `cursor` | String | No | — | Opaque per-topic snapshot/keyset cursor returned as `next_cursor` |
| `limit` | Integer | No | 50 | Messages **per topic** (max 200) |
| `order` | String | No | `"asc"` | Rendering order in the window: `asc` (transcript) or `desc` |
| `max_message_id` | Integer | No | — | Snapshot anchor: only messages with `id <=` this |
| `content_offset` | Integer | No | 0 | Character offset within the first message selected by `offset`; use the returned `next_content_offset` |
| `include_system` | Boolean | No | false | Include authorless notices. Approval prompts are never returned |
| `max_chars` | Integer | No | 40000 | Cap for the **whole response** (min 160, max 200000; smaller positive values are raised to 160) |
| `format` | String | No | `"markdown"` | `markdown` or `json` |

**Windowing.** Selection is always from the newest end: `offset: 0` is the latest
message. `order` only changes how the selected window is rendered, not which
messages it contains. With several topics, `offset`/`limit` apply to **each topic
independently** and results are grouped per topic — never merged into one
timeline, so an offset stays reproducible.

**Paging a long topic.** Take `newest_message_id` and `next_cursor` from the
first page and pass them as `max_message_id` and `cursor` on every later page.
The snapshot excludes newly-created messages and older messages moved into the
topic after page one. The keyset cursor also prevents messages that leave from
shifting unread rows past the offset. It binds a clipped continuation to the
row's content version, so an edit restarts that changed message at character
zero instead of skipping text.

```
topic_messages(topic_ids: "12,45,78", limit: 100)          # summarize three topics
topic_messages(topic_ids: 12, offset: 100, cursor: "1770000000000000:9820:1770000001000000:1770000002000000", max_message_id: 9931)  # next page
topic_messages(topic_ids: 12, offset: 100, cursor: "1770000000000000:9820:1770000001000000:1770000002000000", content_offset: 28400, max_message_id: 9931)  # clipped tail
```

**Returns (json):** `{ topics[], truncated, max_chars }`. Each topic entry:
`topic_id`, `topic_name`, `creative_id`, `total_count`, `total_chars`, `offset`,
`limit`, `returned_count`, `returned_chars`, `has_more`, `next_offset`,
`next_cursor`, `next_content_offset`, `newest_message_id`, `messages[]`, and `budget_limited`
when `max_chars` (rather than `limit`) ended the window. Each message: `id`,
`author`, `author_id`, `agent`, `created_at`, `content` (plain text plus one
URL-bearing metadata marker per image attachment), plus content range fields
when the row is continued.

Attachment markers include filename, content type, byte size, and a readable
public-asset URL. Because they are part of `content`, image-only comments remain
visible and long attachment lists page through `content_offset` without evading
`max_chars`.

A topic the budget could not reach at all comes back with `skipped_reason` and
`returned_count: 0` rather than looking like an empty conversation.

If the fixed topic metadata alone cannot fit — for example, because a topic
name is unusually long — the tool returns a bounded error instead of emitting
a response wider than `max_chars` or silently omitting a topic.

A single message wider than the whole `max_chars` cap is clipped rather than
dropped — dropping it would return an empty page at an offset that has rows and
the caller would page against it forever. A clipped row keeps `next_offset` on
the same message and returns `next_content_offset`; pass both values with the
same `next_cursor` and `max_message_id` until `next_content_offset` disappears.
Only then is the message row consumed. The clip notice is separate from
`content`, so JSON callers can concatenate fragments without stripping tool
text.

Markdown `More:` calls repeat the resolved `limit` and `max_chars` alongside
the cursor, snapshot, content offset, order, and system-message scope. Following
the generated call therefore keeps the same page size and context budget.

Asking for more than 20 topics in one call is an error, not a silent trim — the
ids past the cap were never read, so there would be no per-topic entry to say
they were missing. Split them across calls. (Unknown or unreadable ids are
different: those are reported per topic and the call continues.) `topic_list`
applies the same cap to `topic_ids`.

Requires **read** on each topic's Creative. Private messages you are not party
to are always excluded.

### topic_create

Create a topic on a Creative. The fan-out primitive.

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `creative_id` | Integer | **Yes** | — | Creative to create the topic on |
| `name` | String | No | `"Topic N"` | Must be unique on the Creative |
| `primary_agent` | String | No | — | Agent to pin — id, email, or exact name; private agents already shared here resolve too |
| `comment_ids` | String | No | — | Existing messages to **move** into the new topic |

Pinning a `primary_agent` is **exclusive**: the pinned agent alone answers
ambient messages in the topic and every other agent is silent. The agent must
already hold **feedback** or better on the Creative, otherwise the pin is
refused — a pinned agent that cannot answer would silence the topic entirely.

Requires **write** on the Creative. Use `topic_branch` to copy messages instead
of moving them.

### topic_message_create

Post one public message to an existing topic and run the topic's normal agent
routing. This is the step that turns a newly created, pinned topic into active
work.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `topic_id` | Integer | **Yes** | Topic to post to |
| `content` | String | **Yes** | Message body or initial instruction; Markdown is supported |

The caller remains the visible author. Human-authored messages follow ordinary
comment dispatch. Agent-authored messages dispatch as A2A work, so a coordinator
can create several topics, pin a primary agent on each, then start them with
independent instructions. Different topics can run concurrently; repeated
messages in one topic follow that topic's queue.

An agent cannot call this tool on the topic of its current turn. Continue that
work in the current turn; use this tool to start work in a different topic.

Requires **feedback** or better on the topic's Creative. Archived Creatives,
archived topics, and an inbox's reserved System topic reject new messages.

### topic_update

Rename, archive/unarchive, or re-pin a topic. Pass only what changes.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `topic_id` | Integer | **Yes** | Topic to update |
| `name` | String | No | New name (requires **admin**) |
| `archived` | Boolean | No | `true` archives, `false` unarchives (requires **write**) |
| `primary_agent` | String | No | Agent id/email/name, or `"none"` to clear (requires **write**; private agents already shared here resolve too) |

Archiving hides the topic from the active list but keeps every message, and
`topic_messages` can still read it by id. Archive a topic when its thread has
reached a conclusion rather than reusing it for the next subject.

Main and an inbox Creative's System topic are reserved. Their names and archive
state cannot change because message routing looks them up by name; their primary
agent pin can still change.

A Claude Channel session topic's pin is part of its session identity and cannot
be changed here.

**Returns:** the topic payload plus `changed[]` naming the fields that moved.

### topic_move

Move one complete topic to another Creative.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `topic_id` | Integer | **Yes** | Topic to move |
| `creative_id` | Integer | **Yes** | Destination Creative; links resolve to their origin |

The topic keeps its id, messages, archive state, and read cursors. Its primary
agent stays pinned only when it can still respond on the destination; otherwise
the result reports that the pin was released. Creative permissions do not move,
so verify that participants can access the destination. Active agent work must
finish or be cancelled before the topic can move.

Requires **admin** on the source and **write** on the destination. Topic names
must be unique on the destination. Main, an inbox's System topic, and live agent
session topics cannot move.

**Returns:** the moved topic payload, `moved_from_creative_id`, and an optional
`released_primary_agent` explanation.

### topic_branch

Create a new topic containing **copies** of selected messages. The originals stay
in place — the context-length escape hatch.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `source_topic_id` | Integer | **Yes** | Topic to branch from |
| `comment_ids` | String | **Yes** | Messages to copy, e.g. `"991,994,1002"` (max 100) |
| `name` | String | No | Defaults to `"branch:<source name>"` |

Get the ids from `topic_messages`. Asking for more than the cap is an error, not
a silent trim. Requires **feedback** or better on the Creative.

Approval prompts cannot be branched. The copy carries the content but not the
approval action, so it would stop being excluded from agent history and read as
an ordinary message. Passing one is an error — `topic_messages` never returns
their ids in the first place. Image attachments, including image-only messages,
remain attached to the copies.

## meta_tool

Introspect and dynamically run any registered MCP tool. Enables tool discovery without CLI updates.

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `action` | String | **Yes** | — | `list`, `list_summary`, `search`, `get`, or `run` |
| `tool_name` | String | No | — | Target tool name (required for `get` and `run`) |
| `query` | String | No | — | Search term (for `search` action) |
| `arguments` | Object | No | `{}` | Arguments to pass to the tool (for `run` action) |

**Actions:**

| Action | Description |
|--------|-------------|
| `list` | Full list of all tools with names, descriptions, and parameters |
| `list_summary` | Compact list with names and one-line descriptions only |
| `search` | Filter tools by name or description matching `query` |
| `get` | Full schema for a single tool (params, types, usage) |
| `run` | Execute a tool by name, passing `arguments` through |

**CLI mapping:**

| CLI Command | meta_tool Action |
|-------------|------------------|
| `collavre tool list` | `list_summary` |
| `collavre tool list --full` | `list` |
| `collavre tool search <q>` | `search` |
| `collavre tool info <name>` | `get` |
| `collavre tool run <name>` | `run` |
