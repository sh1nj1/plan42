# Creatives#index N+1 removal (browse tree)

Status: **implemented**. Measured under an identical harness (test suite, warmed
caches, query cache cleared per request): rendering 10 more siblings cost 70 more
queries before (7.0/node) and 0 more after — 47→117 vs a flat 18→18.

## Problem

The main page (`Collavre::CreativesController#index`, JSON) issues 181–824 queries per
request. With Postgres now reached over the network, each query costs a 6.2–8.9 ms
round trip (measured: an idle `SELECT 1` with the AR query cache off takes 6.18 ms),
so response time tracks query count almost exactly:

| queries | response |
|---|---|
| 181 | 1.18 s |
| 378 | 2.06 s |
| 824 | 5.25 s |

Slope ≈ 6.5 ms/query; 85–95 % of the request is ActiveRecord, view render is 0.1–13 ms.
Under SQLite the same 181 queries were in-process (~0.01 ms each), which is why this
never showed up before.

## Where the queries come from

Per rendered node, in `Collavre::Creatives::TreeBuilder#build_nodes_for_creative`:

| # | source | queries/node |
|---|---|---|
| 1 | `filtered_children_for` (`tree_builder.rb:105`) → `children_with_permission` (`permissible.rb:20-62`): origin, children pluck, cache lookup ×2, owned pluck, ordered load | ~5–6 |
| 2 | `creative.parent.nil?` (`tree_builder.rb:125`) | 1 |
| 3 | `render_creative_progress` (`creatives_helper.rb:28-87`): `has_permission?(:feedback)` (39), `effective_origin` (40), `CommentReadPointer.find_by` (42), unread count (44), `has_permission?(:write)` (73), `tags.includes(:label)` (84) | ~4–6 |
| 4 | `inline_editor_payload_for` (`tree_builder.rb:193-204`): `effective_origin`, `has_permission?(:write)` for shells, `effective_description` | ~1–3 |

Two structural notes:

- **`filtered_children_for` runs unconditionally** (line 105), *before* the
  `load_children_now` check on line 111. So a collapsed node — invisible on screen —
  still loads its whole child set, only to derive `has_children:` (line 136). Those
  children then recurse into the same work.
- **`TreeBuilder#preload_permissions` (lines 32-74) is nearly dead weight.** It caches a
  `:write` boolean, but the helper re-asks via `has_permission?` (`creatives_helper.rb:39, 73`),
  which goes through `PermissionChecker` and bypasses the cache entirely.

The 824-query case is the tag filter: `ProgressService#progress_for_tags`
(`progress_service.rb:54-72`) walks the entire subtree recursively, calling
`children_with_permission` (≈5 queries) per descendant plus `tags.pluck` per leaf.

## The fix already exists in this repo

The picker popup solved the same problem: `CreativeTreeSerializer#children_presence_set`
(`creative_tree_serializer.rb:101-119`) answers "does this node have visible children?"
with **one** `where(parent_id: origin_ids)` plus one batched
`PermissionFilter#readable_ids` (`permission_filter.rb:16`) — no per-node work. The
browse path just never adopted it. This is a port, not a design.

## Changes

All inside the browse path. No migration, no infra change, no downtime.

1. **`has_children` without loading children.** Extract `children_presence_set` into a
   shared `Creatives::ChildrenPresence` and call it once per level. Load real children
   only when `load_children_now` is true. *Must* intersect `allowed_creative_ids` and
   the archived filter, or a toggle opens an empty branch (the picker version skips
   this because the picker has no such filter).
2. **Batch the children load per level.** One `Creative.where(parent_id: origin_ids).order(:sequence)`
   plus one `PermissionFilter#readable_ids`, grouped by parent — replacing per-node
   `children_with_permission`. Children of linked shells live under `effective_origin`,
   so map origin id → node id as the serializer does (line 104).
3. **Preload per level:** `origin`, `tags → label`. Replace `creative.parent.nil?`
   (line 125) with `creative.parent_id.nil?` — same answer, zero queries (verify no rows
   have a dangling `parent_id`).
4. **Make the permission cache actually serve the helper.** Store the effective *rank*
   per creative id instead of a `:write` boolean, so `:feedback` and `:write` both
   resolve from memory. Pass `can_write:` / `can_feedback:` into `render_creative_progress`,
   keeping the `has_permission?` fallback for its other call sites.
5. **Batch the comment badge:** one `CommentReadPointer.where(user:, creative_id: origin_ids)`
   and one `GROUP BY creative_id` unread count per level, instead of 2 queries per node.
6. **Tag-filter rollup:** feed `progress_for_tags` the same batched children map and
   batch `tags.pluck(:label_id)` across the subtree. This is what collapses the 824 case.

## Expected result

Per **level** ~5–8 queries, independent of node count.

| | before | after |
|---|---|---|
| main page | 181 q / 1.18 s | ~15–25 q / ~0.15 s |
| tag filter | 824 q / 5.25 s | ~30 q / ~0.2 s |

Holds on the *current* remote DB. Moving the DB onto the app's network multiplies with
this rather than substituting for it.

## Test first

The invariant is *query count must not scale with node count*. Seed a 2-level tree of
N nodes, hit `Collavre::CreativesController#index`, and assert the query count for 40
nodes exceeds the count for 20 nodes by at most a small constant. That test fails today
(it grows ~10–13 per node) and passes after. Run from the host root:
`bin/rails test engines/collavre/test/...`.

## Risks

- **has_children parity.** Presence must match exactly what expanding shows (archived +
  permission + `allowed_creative_ids`), or the toggle hides a reachable subtree or opens
  an empty one — and an empty-open leaks that hidden children exist.
- **Permission posture drift.** `PermissionFilter` is `:read` with `no_access`
  subtraction; `children_with_permission` takes a `min_permission`. Keep `:read`
  semantics identical when porting.
- **Linked shells.** Children hang off `effective_origin`, not the shell row.

## Out of scope

Availability: production Postgres currently runs on the local MacBook
(`macbook-pro.tailadceed.ts.net`), so the app dies when it sleeps. This plan does not
address that.
