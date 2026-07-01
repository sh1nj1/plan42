# Task 8 Report — Mark IssueLink dirty on change + Archive on destroy

## Fix 1 — Mark IssueLink dirty before enqueue (non-destroy paths)

**File changed:** `engines/collavre_linear/app/observers/collavre_linear/creative_sync_observer.rb`

- Added `mark_issue_link_dirty` private method: reads `linear_issue_links.first` and calls `update_column(:sync_state, :dirty)` when a link exists.
- Called from `enqueue_linear_outbound_sync` in the non-destroy branch (before enqueuing `OutboundSyncJob`).
- No-ops when no IssueLink exists (new creative; `linear_issue_id` is NOT NULL so a link can't exist before the API create).

**Test added:** `creative_sync_observer_test.rb` — "updating a linked creative that already has an IssueLink marks it dirty and still enqueues": creates an IssueLink with `sync_state: :synced`, updates the creative, asserts link is `:dirty` and `OutboundSyncJob` is enqueued.

## Fix 2 — Archive Linear issue on Creative destroy

### 2a — Client: `archive_issue`

**File changed:** `engines/collavre_linear/app/services/collavre_linear/client.rb`

- Added `ISSUE_ARCHIVE` constant (mutation `issueArchive(id: String!){ success }`).
- Added `archive_issue(id)` method returning boolean.

**Test added:** `client_test.rb` — "archive_issue posts issueArchive mutation and returns true on success": WebMock stubs the endpoint, verifies the mutation name and `id` variable.

### 2b — Capture linear_issue_id before destroy

**File changed:** `engines/collavre_linear/app/observers/collavre_linear/creative_sync_observer.rb`

- Added `attr_accessor :_linear_archive_issue_id, :_linear_archive_account_id` in `included do`.
- Added `before_destroy :capture_linear_archive_info, prepend: true` — **`prepend: true` is critical**: the `has_many :linear_issue_links, dependent: :destroy` association callback is registered before our hook (engine initializer order), so without `prepend: true` our hook runs after IssueLinks are already deleted and finds nothing.
- `capture_linear_archive_info` reads `linear_issue_links.first` and stores `linear_issue_id` + `project_link.account_id` on transient attrs.

**No schema change:** `has_many :linear_issue_links, dependent: :destroy` was already in `engine.rb` (`creative_associations` initializer). No FK violation risk; dependent destroy is already configured.

### 2c — OutboundArchiveJob

**File created:** `engines/collavre_linear/app/jobs/collavre_linear/outbound_archive_job.rb`

- `perform(linear_issue_id, account_id)`: loads `CollavreLinear::Account`, builds `Client`, calls `client.archive_issue(linear_issue_id)`.
- `retry_on CollavreLinear::Client::Error`.
- Silently skips if account not found (`ActiveRecord::RecordNotFound`).

**Observer destroy branch:** `enqueue_linear_outbound_sync` on `destroyed?` calls `enqueue_archive_if_captured` which only enqueues when both transient attrs are set (i.e., an IssueLink existed). No OutboundSyncJob is enqueued for destroy.

### 2d — Tests

**Tests added in `creative_sync_observer_test.rb`:**
1. "destroying a linked Creative with an IssueLink enqueues OutboundArchiveJob with linear_issue_id and account_id"
2. "destroying a linked Creative with NO IssueLink enqueues nothing"
3. "destroying an unlinked Creative enqueues nothing"

**File created:** `engines/collavre_linear/test/jobs/collavre_linear/outbound_archive_job_test.rb`
- "perform_later enqueues the job with linear_issue_id and account_id"
- "perform calls client.archive_issue with the linear_issue_id"
- "perform is silent when account does not exist"

## No migration / schema changes

No new columns or tables. No `db/schema.rb` changes.

## Test run

```
cd /Users/soonoh/project/soonoh/plan42-worktree9 && bin/rails test engines/collavre_linear/test/
152 runs, 340 assertions, 0 failures, 0 errors, 0 skips
```

Covering test files:
- `test/observers/collavre_linear/creative_sync_observer_test.rb`
- `test/services/collavre_linear/client_test.rb`
- `test/jobs/collavre_linear/outbound_archive_job_test.rb`
- (plus all pre-existing 149 tests passing)
