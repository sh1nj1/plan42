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
| `description` | String | **Yes** | — | Content/title (HTML or plain text) |
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
| `description` | String | No | — | New content/title |
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
