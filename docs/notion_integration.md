# Notion Integration

The Notion engine exports a selected Creative and all active descendants as a
nested tree of **pages**. Each Creative, including empty and leaf items, owns a
page directly under its parent's page. Depth is not flattened into headings or
bullet lists.

## Setup

Connect a Notion integration with read, insert, and update content capabilities.
Configure `notion.client_id` / `notion.client_secret` in Rails credentials or
`NOTION_CLIENT_ID` / `NOTION_CLIENT_SECRET` in the environment. The callback is
`/auth/notion/callback`. Share the destination page with the integration.

Run `bin/rails db:migrate`; migrations live in `engines/collavre_notion/db/migrate`.

## Export and sync

1. Open the Creative's Notion integration and connect an account.
2. Choose a destination page and export. Without an explicit destination, the
   integration reuses the first existing export or selects an accessible page.
3. Use Sync to update the linked export. Both background jobs use the same tree
   synchronization service.

For `A → B → C`, the result is `page A → page B → page C`. Siblings are initially
created in Creative order. A description supplies the page title (up to 2,000
characters) and its own body. Long text is split into paragraphs without
truncation. HTML and Markdown tables are converted to table blocks; long cells
are split into rich text entries and large tables into batches of 100 rows.
Existing image attachment placeholders remain supported; this is not a full
rich-text or binary attachment fidelity exporter.

Each selected destination owns independent mappings. Exporting the same tree to
another parent does not move or overwrite the earlier export. Re-exporting to the
same parent reuses the existing pages. Sync uses its exact `NotionPageLink`.

Within a tree, new items create pages and moved items move their existing pages,
retaining IDs and Notion-added content. Removed, archived, and moved-out items
are archived in Notion after the active tree has synchronized. This moves the
entire generated page, including user additions, to Notion's trash; it does not
permanently delete content. Descendants are archived before their parents.
Disconnecting an integration only removes local mappings, leaving Notion pages.

## Ownership and legacy exports

`NotionPageLink` represents an export root. `NotionPageNode` records each
Creative's page ID, parent page ID, body block IDs, and content hash within that
export. Its source ID deliberately has no Creative foreign key: a hard-deleted
Creative must remain identifiable until the next sync archives its remote page.

Only tracked body blocks are replaced on content changes. Child pages and blocks
added directly in Notion are not cleared. The page title and generated body are
owned by Collavre; edits to them may be replaced when source content changes.
Unchanged source content does not perform drift detection against Notion.

Legacy heading/bullet exports keep their root page. Sync first creates the page
tree, then removes only blocks tracked by the old `NotionBlockLink` records.
Untracked legacy blocks and user-added content are retained, since their ownership
cannot be determined safely.

## Reliability and API limits

- An account-scoped lock serializes exports and syncs. PostgreSQL uses a session
  advisory lock; SQLite uses a file lock alongside the database, shared across
  workers using that database.
- Each completed page and body batch is persisted immediately, outside a
  transaction covering the whole remote operation. A failed export can resume
  using those mappings. `last_synced_at` advances only after the entire tree and
  cleanup complete.
- HTTP 429 responses honor `Retry-After` for up to five inline retries. Persistent
  rate limits fall back to the jobs' bounded polynomial retry schedule.
- Other failures propagate. Connection timeouts are **not automatically retried**:
  a remote create may have succeeded without returning its ID. A process failure
  between a successful remote write and local persistence has the same ambiguity.
  Check for an untracked remote page/block before manually retrying that case;
  exactly-once remote creation is not guaranteed.
- Page creation and content requests retain API version `2022-06-28`. Page moves
  explicitly use `2025-09-03` and `POST /v1/pages/{page_id}/move`.
- The [page move endpoint](https://developers.notion.com/reference/move-page)
  accepts a new parent but no sibling position. Existing sibling reordering and
  inserting new pages at a specific sibling position are not synchronized; new
  pages are appended. Existing pages are never recreated merely to reorder them.

## Testing

From the host application root:

```bash
bin/rails test engines/collavre_notion/test/
```

The tests cover deep/empty trees, initial sibling order, repeated and independent
exports, content ownership, moves, removals, legacy conversion, partial failures,
long text and tables, both jobs, locking, and HTTP request/retry contracts. Real
Notion workspace verification remains separate from these mocked API tests.
