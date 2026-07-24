# Permission System

## Permission Levels

Five levels, hierarchical (ascending order):
- `:no_access` - Explicitly blocked
- `:read` - View content
- `:feedback` - View and leave comments
- `:write` - Edit content (includes feedback)
- `:admin` - Manage permissions (includes write)

## Permission Model

Permissions are stored as `CreativeShare` records:

```ruby
class CreativeShare < ApplicationRecord
  belongs_to :user, optional: true  # nil = public share
  belongs_to :creative

  enum :permission, { no_access: 0, read: 1, feedback: 2, write: 3, admin: 4 }
end
```

## Inheritance

Permissions inherit from the **origin** (root) creative:

```ruby
# For nested creatives
creative.effective_origin  # Self if root, else origin

# Permission check considers inheritance (uses CreativeSharesCache)
creative.has_permission?(user, :read)   # => true/false
creative.has_permission?(user, :write)
creative.has_permission?(user, :admin)
```

## Controller Authorization

```ruby
class CreativesController < ApplicationController
  before_action :set_creative
  before_action :ensure_read_permission
  before_action :ensure_write_permission, only: [:edit, :update]
  before_action :ensure_admin_permission, only: [:destroy]

  private

  def ensure_read_permission
    return if @creative.has_permission?(Current.user, :read)
    render_forbidden
  end

  def ensure_write_permission
    return if @creative.has_permission?(Current.user, :write)
    render_forbidden
  end

  def ensure_admin_permission
    return if @creative.has_permission?(Current.user, :admin)
    render_forbidden
  end
end
```

## Creating Permissions

```ruby
# Grant access
CreativeShare.create!(user: user, creative: root_creative, permission: :write)

# Via invitation
Invitation.create!(
  inviter: current_user,
  creative: creative,
  permission: :read
)
```

## Owner Permissions

The creative's owner (`user_id`) always has admin access. This is enforced in
`Collavre::Creatives::PermissionChecker`, which grants the owner full access
regardless of any `CreativeShare` record.

---

# Converged Permission Architecture

> This section documents the FINAL state of the permission system after the
> "rot ②" convergence effort (the security-audit's #1 rot core), which landed
> across PRs **#1388–#1393**, **#1396**, and **#1397**. It is the foundation the
> upcoming skill-tree permission layer will build on, so the invariants below
> are load-bearing.

The permission system has two halves that must stay in agreement:

- **Read path** — "given a user and a set of creative ids, which may they see
  (at some rank)?" Answered from the O(1) `CreativeSharesCache` table.
- **Write-invalidation path** — "when a share or a creative changes, which cache
  rows must be rebuilt so the read path stays correct?" Handled by model
  callbacks that enqueue `PermissionCacheJob` (queue `authz`).

The convergence effort collapsed each half onto a single canonical
implementation so that no future code path can quietly disagree with the
authoritative resolution.

> **Cache lifetime — no TTL, no env var.** The permission cache is a **database
> table** (`creative_shares_caches`) kept correct by invalidation jobs, **not** a
> time-expiring `Rails.cache` store. There is deliberately no cache-expiry
> environment variable: correctness comes from the invalidation invariant below,
> not from a timeout. (A now-removed doc described a `PERMISSION_CACHE_EXPIRES_IN`
> knob and per-key `Rails.cache` entries — neither exists in the code.)

## 1. Single Read Path — `PermissionFilter`

**File:** `engines/collavre/app/services/collavre/creatives/permission_filter.rb`

`PermissionFilter` is the one place the batch read-authorization posture lives.
It resolves each id to its effective (origin) creative using the SAME logic as
the single-item `PermissionChecker`, then applies the deny-invariant:

- **Owner wins** — the owner resolves to `admin` (top rank) and satisfies any
  threshold.
- **User entry is authoritative over public** — a user-specific
  `CreativeSharesCache` row grants only when its own rank meets the requested
  `min_permission`, and otherwise **suppresses** the public share entirely. So a
  user `no_access` (rank 0) — or any below-threshold user entry — beats a more
  permissive public share.
- **Public share** applies only when the user has no own entry.

Two entry points:

- `readable_ids(ids, min_permission:)` — returns the accessible subset as an
  Array, and additionally applies the **shell placement anti-leak gate**: a
  linked "shell" creative is returned only if its origin is readable AND its
  placement is visible to the viewer — i.e. the viewer either owns the shell row
  or the shell sits in a subtree shared with the viewer (a propagated
  `CreativeSharesCache` entry on the shell row itself, e.g. a public help doc's
  linked child). The placement is checked at the caller's `min_permission`, not
  hardcoded to `:read`, so a viewer with only read on a shared tree cannot reach
  a shell that requires `admin` (e.g. recursive delete). A shell in a foreign
  private tree has no entry and stays hidden (a batch can be fed foreign shells).
- `ranks_for(ids)` — returns `{ id => rank }` for callers that already operate
  inside the viewer's own tree and want the raw rank (no shell gate).

### Read sites that converged

PR #1388 pinned the observable behavior of the **five** read sites that queried
`CreativeSharesCache` directly, as characterization tests
(`permission_read_characterization_test.rb`) — the safety net for the rewrites.
Four then converged onto `PermissionFilter`, each proven behavior-preserving:

| Site | Location | Converged in |
| --- | --- | --- |
| `Creative#children_with_permission` | `creative/permissible.rb` | #1390 |
| `SlideViewable#accessible_child_ids` | `concerns/slide_viewable.rb` | #1391 |
| `TreeBuilder#preload_permissions` | `creatives/tree_builder.rb` | #1391 |
| `AttachmentsController#editable_creative_reference?` | `attachments_controller.rb` | #1392 |

PR #1389 first extended `PermissionFilter` with `min_permission:` and
`ranks_for` so the write-posture site (attachments, `:write`) and the
rank-consuming sites (tree/slide) could share the one filter.

### The one site deliberately left out

`Tools::CreativeRetrievalService#accessible_creative_ids`
(`accessible_creative_ids`) was NOT converged. It has a deliberate **posture
divergence**: it returns the user's own creatives plus their user-specific cache
entries with `.where.not(permission: :no_access)`, and **ignores public shares
entirely**. Because it neither honors public shares nor applies origin/shell
resolution, routing it through `PermissionFilter` would change its observable
result — so it was left as-is with its characterization test locking the
divergence. (Tracked separately as issue #855.) It is safe precisely because it
is strictly narrower than the canonical path (own + explicit user grants only).

## 2. Single Write-Invalidation Dispatcher (declarative)

Both models that can invalidate the cache now use the same shape: a declarative
**`PERMISSION_INVALIDATING_ATTRIBUTES`** map from persisted attribute → rebuild
operation, consumed by a **single `after_commit` dispatcher**. This replaced
hand-coded `saved_change_to_*` callback chains, so a new mutation path cannot add
a column without deciding (in the map) how it invalidates — see the invariant
below.

### `CreativeShare` — unconditional re-propagate (#1393)

**File:** `engines/collavre/app/models/collavre/creative_share.rb`

- Map: `creative_id → :relocate`, `user_id → :reassign`,
  `permission → :repropagate`.
- `dispatch_share_cache_invalidation` (`after_commit on: [:create, :update]`)
  **always** enqueues `PermissionCacheJob(:propagate_share)` — an
  **unconditional, fail-closed** refresh. It does NOT gate on which attribute
  changed for the base refresh.
- **Why unconditional here:** `after_commit` sees only the *final* save's
  `saved_changes`. In a multi-save transaction, an earlier permission change can
  be clobbered out of the final `saved_changes`; a `saved_changes`-gated
  dispatcher would then skip the refresh and leave the cache stale (fail-**open**,
  no TTL/self-heal). Always re-propagating is the fail-closed choice. This is the
  Codex fix `00502d7d`.
- A move (`creative_id`) or reassignment (`user_id`) needs EXTRA cleanup on top
  of the base refresh: the stale rows the share left at the old location must be
  purged, and the vacated subtree rebuilt for the old user. The map drives that
  extra work; the base refresh always runs regardless.

### `Creative::Permissible` — cross-save accumulation (#1396)

**File:** `engines/collavre/app/models/collavre/creative/permissible.rb`

- Map: `parent_id → :rebuild`, `user_id → :rebuild_owner`,
  `origin_id → :rebuild` (`origin_id` is immutable post-create via
  `attr_readonly`, so its entry is defensive).
- Solves the **same** multi-save clobber, but with **cross-save accumulation**,
  NOT an unconditional refresh:
  - `after_save :accumulate_permission_cache_changes` merges each save's relevant
    `saved_changes` into an ivar (`@accumulated_permission_changes`), keeping the
    earliest `old` and latest `new`.
  - `after_commit :dispatch_permission_cache_invalidation` maps the accumulated
    changes through the registry and enqueues each distinct rebuild once, then
    clears the ivar.
  - `after_rollback :clear_accumulated_permission_changes` resets it.
- **Why accumulation instead of unconditional (the hot-path distinction):**
  `rebuild_for_creative` is a **subtree rebuild** on a hot write path — Creatives
  are re-saved constantly for permission-irrelevant reasons (progress rollup,
  description edits). Refreshing unconditionally on every Creative commit would
  regress throughput. Accumulation keeps permission-irrelevant saves cheap while
  still never dropping a real permission change.

**Honest scope note:** this is a *defensive/latent* fix. No production path today
performs two real saves touching a permission attribute then an untracked column
on one Creative in a single transaction (the reorderer re-saves `:sequence` via
`update_column`, which bypasses these callbacks and preserves `saved_changes`).
The clobber is sealed against, but the exposure it seals was **unreachable**, not
actively firing — the latent risk is closed as follow-up hardening, not a live
bug that was leaking.

## 3. Async Delete-Timing — folded purge (#1397)

**Files:** `creative_share.rb`, `permission_cache_job.rb`, `config/queue.yml`

Previously the stale-cache purge for a relocated/reassigned share ran
synchronously as `delete_all` inside `after_commit`. It is now **async and
folded into the `propagate_share` job** via a `purge_stale:` flag:

- `dispatch_share_cache_invalidation` sets `propagate_args[:purge_stale] = true`
  for a relocate/reassign and enqueues a single
  `PermissionCacheJob(:propagate_share, purge_stale: true)`.
- Inside the job, `purge_share_cache` (deletes rows keyed on `source_share_id`)
  runs **immediately before** re-propagating, **in the same job** — never as a
  standalone enqueue.

**Why folded, not a standalone purge job (Codex fix `82d1e013`):** the `authz`
queue runs **2 threads** (`config/queue.yml`). Both the purge and the propagate
key on `source_share_id`, so a *separate* purge job could execute on the second
thread AFTER propagate and delete the rows propagate just wrote — dropping the
share's access until an unrelated rebuild. Folding the purge into the same job
guarantees purge-before-propagate ordering.

**Accepted design decision — the prolonged-grant window:** moving the purge off
the commit path means the revoke of the vacated access is deferred by the queue
latency (~1–2s). This is acceptable **without a TTL** because the deferred purge
only ever **prolongs an already-granted permission** by that window — it never
grants NEW access. (A move/reassign's *base refresh* still re-propagates the
share's current grant unconditionally; only the cleanup of the OLD location is
deferred.) The CTO accepted this window for the perf win.

## 4. The Invariant

**A new mutation path must not silently skip cache invalidation.**

Concretely, when adding a persisted attribute or a new write path to
`CreativeShare` or `Creative`:

- Decide, in `PERMISSION_INVALIDATING_ATTRIBUTES`, whether/how it invalidates.
- The single `after_commit` dispatcher then handles it — there is no second,
  hand-rolled callback chain to keep in sync.
- Prefer fail-**closed**: when in doubt, refresh. The `CreativeShare` base
  re-propagate is unconditional for exactly this reason; `Creative` uses
  accumulation only because its rebuild is hot-path and it can prove no real
  path drops a change.

## Forward Context — Skill-Tree Permissions

The skill-tree permission layer will sit ON TOP of this converged foundation.
Because there is now exactly one read resolver (`PermissionFilter`) and one
declarative write-invalidation dispatcher per model, the skill-tree work can:

- Extend the read posture in a single place rather than re-deriving the
  deny-invariant at each call site.
- Add new invalidating attributes/edges by extending the declarative maps,
  inheriting the "cannot silently skip invalidation" invariant for free.
