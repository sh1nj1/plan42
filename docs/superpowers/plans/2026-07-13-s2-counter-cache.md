# S2 — counter_cache for comments/comment_versions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate two per-row `COUNT` N+1s in list rendering by adding Rails `counter_cache` columns `creatives.comments_count` and `comments.comment_versions_count`, backfilled and wired into the exact hot sites.

**Architecture:** Both target associations have **no soft-delete and no scoping** (`dependent: :destroy`, plain columns), so a raw Rails `counter_cache` stays correct on create/destroy. `comments_count` counts **all** comments (matches `creatives_helper.rb:41`'s `origin.comments.size`). It deliberately does **not** replace `broadcastable.rb:33`'s `public_only.count` (public-only ≠ all-rows) nor any `id > last_read_id` unread threshold logic. Backfill uses a raw-SQL `UPDATE … SET n = (SELECT COUNT(*) …)` in the migration `up`, matching house style.

**Tech Stack:** Rails 8.1 (`ActiveRecord::Migration[8.1]`), Minitest, engine `collavre`. This project has **no existing counter_cache** — we are establishing the pattern.

## Global Constraints

- Engine `collavre`. Run engine tests from **host root**: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test/...`.
- PR/commit messages **English**, Conventional Commits.
- Migrations live in `engines/collavre/db/migrate/`, class base `ActiveRecord::Migration[8.1]`, timestamp `20260713000001+` (must sort after `20260702000005`). Update root `db/schema.rb` via migration run (do not hand-edit schema).
- **Do NOT** touch `broadcastable.rb:33` (`public_only.count`) or unread `id > last_read_id` logic — different semantics.
- `comments_count` = ALL comments (public + private). `comment_versions_count` = all versions of a comment.
- No soft-delete exists on these tables — backfill is a straight COUNT.

---

### Task 1: `creatives.comments_count` counter_cache

**Files:**
- Create: `engines/collavre/db/migrate/20260713000001_add_comments_count_to_creatives.rb`
- Modify: `engines/collavre/app/models/collavre/comment.rb:54` (add `counter_cache: true` to `belongs_to :creative`)
- Modify: `engines/collavre/app/helpers/collavre/creatives_helper.rb:41` (use the cached column)
- Test: `engines/collavre/test/models/comment_test.rb` (counter behavior)

**Interfaces:**
- Produces: `creatives.comments_count` (integer, default 0, not null) maintained automatically by Rails on `Comment` create/destroy; `Collavre::Creative#comments_count` reader.

- [ ] **Step 1: Write the failing test**

Add to `engines/collavre/test/models/comment_test.rb`:

```ruby
test "creating and destroying a comment maintains creatives.comments_count" do
  user = User.create!(email: "cc-counter@example.com", password: TEST_PASSWORD, name: "CC")
  creative = Creative.create!(user: user, description: "Root")
  assert_equal 0, creative.comments_count

  c1 = Comment.create!(creative: creative, user: user, content: "one")
  Comment.create!(creative: creative, user: user, content: "two", private: true)
  assert_equal 2, creative.reload.comments_count, "counts all comments incl. private"

  c1.destroy!
  assert_equal 1, creative.reload.comments_count
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test/models/comment_test.rb -n "/comments_count/"`
Expected: FAIL (`comments_count` NoMethodError — column absent).

- [ ] **Step 3: Write the migration (add column + backfill)**

Create `engines/collavre/db/migrate/20260713000001_add_comments_count_to_creatives.rb`:

```ruby
class AddCommentsCountToCreatives < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:creatives, :comments_count)
      add_column :creatives, :comments_count, :integer, default: 0, null: false
    end

    # Backfill: straight COUNT (no soft-delete on comments). Matches house
    # raw-SQL backfill convention.
    execute <<~SQL.squish
      UPDATE creatives
      SET comments_count = (
        SELECT COUNT(*) FROM comments WHERE comments.creative_id = creatives.id
      )
    SQL
  end

  def down
    remove_column :creatives, :comments_count if column_exists?(:creatives, :comments_count)
  end
end
```

- [ ] **Step 4: Add counter_cache to the association**

In `engines/collavre/app/models/collavre/comment.rb:54`, change:

```ruby
belongs_to :creative, class_name: "Collavre::Creative", counter_cache: true
```

- [ ] **Step 5: Run the migration and the test**

Run:
```bash
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails db:migrate
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test/models/comment_test.rb -n "/comments_count/"
```
Expected: migration adds the column + updates `db/schema.rb`; test PASS.

- [ ] **Step 6: Rewire the helper hot site**

In `engines/collavre/app/helpers/collavre/creatives_helper.rb`, line 41 currently:
```ruby
comments_count = origin.comments.size
```
Change to use the cached column (avoids the per-creative COUNT):
```ruby
comments_count = origin.comments_count
```
Leave lines 42-44 (`CommentReadPointer` lookup and `unread_count` via `id > last_read_id`) **unchanged** — unread is threshold-based, not a counter. Verify `origin` is a `Creative` (it is — `creative.effective_origin`, line 40).

- [ ] **Step 7: Commit**

```bash
git add engines/collavre/db/migrate/20260713000001_add_comments_count_to_creatives.rb \
        engines/collavre/app/models/collavre/comment.rb \
        engines/collavre/app/helpers/collavre/creatives_helper.rb \
        engines/collavre/test/models/comment_test.rb \
        db/schema.rb
git commit -m "perf(creatives): add comments_count counter_cache for list rendering"
```

---

### Task 2: `comments.comment_versions_count` counter_cache

**Files:**
- Create: `engines/collavre/db/migrate/20260713000002_add_comment_versions_count_to_comments.rb`
- Modify: `engines/collavre/app/models/collavre/comment_version.rb:7` (add `counter_cache: true` to `belongs_to :comment`)
- Modify: `engines/collavre/app/views/collavre/comments/_comment.html.erb:93-94` (use cached column)
- Test: `engines/collavre/test/models/comment_test.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `comments.comment_versions_count` maintained on `CommentVersion` create/destroy of the `:comment` association. **Only** the `belongs_to :comment` association is counted — NOT `belongs_to :review_comment` (that maps to `has_many :review_versions` and must not get a counter_cache).

- [ ] **Step 1: Write the failing test**

Add to `engines/collavre/test/models/comment_test.rb`:

```ruby
test "creating and destroying versions maintains comment_versions_count" do
  user = User.create!(email: "cv-counter@example.com", password: TEST_PASSWORD, name: "CV")
  creative = Creative.create!(user: user, description: "Root")
  comment = Comment.create!(creative: creative, user: user, content: "hi")
  assert_equal 0, comment.comment_versions_count

  v1 = CommentVersion.create!(comment: comment, content: "v1", version_number: 1)
  CommentVersion.create!(comment: comment, content: "v2", version_number: 2)
  assert_equal 2, comment.reload.comment_versions_count

  v1.destroy!
  assert_equal 1, comment.reload.comment_versions_count
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test/models/comment_test.rb -n "/comment_versions_count/"`
Expected: FAIL (column absent).

- [ ] **Step 3: Write the migration**

Create `engines/collavre/db/migrate/20260713000002_add_comment_versions_count_to_comments.rb`:

```ruby
class AddCommentVersionsCountToComments < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:comments, :comment_versions_count)
      add_column :comments, :comment_versions_count, :integer, default: 0, null: false
    end

    # Backfill counts only the owning :comment association (comment_id),
    # NOT review_comment_id (review_versions).
    execute <<~SQL.squish
      UPDATE comments
      SET comment_versions_count = (
        SELECT COUNT(*) FROM comment_versions WHERE comment_versions.comment_id = comments.id
      )
    SQL
  end

  def down
    remove_column :comments, :comment_versions_count if column_exists?(:comments, :comment_versions_count)
  end
end
```

- [ ] **Step 4: Add counter_cache to the association**

In `engines/collavre/app/models/collavre/comment_version.rb:7`, change:

```ruby
belongs_to :comment, class_name: "Collavre::Comment", counter_cache: true
```
Leave `belongs_to :review_comment, ... optional: true` (line 8) **unchanged** — no counter_cache.

- [ ] **Step 5: Run the migration + test**

Run:
```bash
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails db:migrate
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test/models/comment_test.rb -n "/comment_versions_count/"
```
Expected: PASS.

- [ ] **Step 6: Rewire the view hot site**

In `engines/collavre/app/views/collavre/comments/_comment.html.erb`, lines 93-94 currently:
```erb
  <% if comment.comment_versions.any? %>
    <% version_count = comment.comment_versions.size %>
```
Change to use the cached column (removes an EXISTS + a COUNT per comment):
```erb
  <% if comment.comment_versions_count > 0 %>
    <% version_count = comment.comment_versions_count %>
```
Line 95 (`selected_id`) and line 96 (`.order(:version_number).pluck(:id)`) stay — line 96 only runs when versions exist, which is now gated by the cached count.

- [ ] **Step 7: Verify the partial renders (real browser, not just unit)**

Per memory (`feedback_collavre_lexical_fence_needs_real_browser`), view changes need a real render check. After the migration, drive the comments view in a preview server and confirm a comment WITH versions still shows its version UI and one WITHOUT versions does not. If a preview server is not spun up in this task, at minimum add/confirm a controller or system test that renders `_comment` for both cases. Grep existing tests: `engines/collavre/test/system/` and `engines/collavre/test/controllers/comments_controller_test.rb` for version-badge assertions and update if they relied on the old association call.

- [ ] **Step 8: Commit**

```bash
git add engines/collavre/db/migrate/20260713000002_add_comment_versions_count_to_comments.rb \
        engines/collavre/app/models/collavre/comment_version.rb \
        engines/collavre/app/views/collavre/comments/_comment.html.erb \
        engines/collavre/test/models/comment_test.rb \
        db/schema.rb
git commit -m "perf(comments): add comment_versions_count counter_cache for comment rendering"
```

---

### Task 3: Full-suite regression + PR

- [ ] **Step 1: Run the full collavre engine suite**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test`
Expected: PASS (modulo pre-existing unrelated reds on main).

- [ ] **Step 2: Confirm schema.rb has both new columns and correct migration versions**

Verify `db/schema.rb` shows `comments_count` on `creatives`, `comment_versions_count` on `comments`, and the schema version bumped to `20260713000002`. Confirm no stray column changes.

- [ ] **Step 3: Push (serial) + PR** — orchestrated externally. PR body: two counter_cache columns, backfilled, wired into `creatives_helper.rb:41` and `_comment.html.erb`; explicitly notes `broadcastable.rb` public_only and unread threshold logic left untouched.

## Self-Review Notes (planner)

- Spec coverage: S2-b = `creatives.comments_count` ✓ (Task 1) + `comments.comment_versions_count` ✓ (Task 2). Unread explicitly excluded per spec.
- Semantic-mismatch trap (public_only vs all-rows) is called out and the public_only site is left alone.
- Only the `:comment` association gets a counter — `:review_comment` explicitly excluded (would double-count / wrong column).
