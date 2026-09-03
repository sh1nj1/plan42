# Creative Change History Rollout

## Goal

Add append-only, auditable version history for Creative trees. One logical actor turn is a `CreativeChangeSet`; each touched Creative is one `CreativeChange`. The system must support multi-Creative document diffs and atomic revert without inventing a page boundary.

## Product decisions

- AI delete archives instead of hard deleting.
- AI writes apply automatically by default and expose undo; review mode is opt-in.
- Human autosaves use a client change-group token and merge until five minutes of inactivity.
- Retention defaults to 50 changes per Creative and 90 days, with admin overrides.
- History is presented in a dedicated `History` topic.

## Data and grouping invariants

- History is append-only. Revert creates a new change set and links it through `reverts_id` / `reverted_by_id`.
- Snapshots contain only Markdown-canonical content and structural fields: `markdown_source`, `content_type`, `editor`, conditional `description`, `parent_id`, `sequence`, `progress`, and `archived_at`.
- `creative_changes` has one row per `[creative_change_set_id, creative_id]`. Repeated writes preserve the first `before` and replace only `after`.
- Change-set lookup joins touched Creative IDs against the viewed Creative's closure-tree descendants. It does not store or infer a page root.
- Diff rendering uses the observed actor location as `anchor_creative_id`. Changes outside that anchor render as multiple top-level groups while revert remains change-set atomic.
- Synced read-only history is hidden by default and cannot be reverted.

## Rollout

1. Add the two history tables, Creative revision, recording hooks, observed anchors, human idle grouping, and read-only history queries. This is shadow-only.
2. Add Markdown document reconstruction, inline/split diff rendering, apply/revert services, conflict handling, permissions, and the dedicated History topic.
3. Change AI deletion to archive, publish applied-change comments, and show a 30-second undo toast.
4. Add inherited `ai_write_policy`, draft change sets, and diff-based approve/reject actions.
5. Add retention cleanup, guarded `SystemSetting` accessors, and English/Korean admin settings.

Each rollout PR targets `feature-revision`. After Codex review and CI pass, it is squash-merged and its Collavre Creatives are completed. When all five are merged, `feature-revision` is squash-merged into `main`.
