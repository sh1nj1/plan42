# T7 original implementation preservation

Recovered on 2026-09-08 from existing checkouts and session records. No implementation was recreated. Original worktrees, branches, tracked files and untracked files were not reset or deleted.

## Source provenance

- Original T7 checkout: `/tmp/plan42-worktree5`, branch `feat/dnd-touch-support`, HEAD `689726b7460889216d4ee47737f280e5c9bb82eb`.
- Original registry checkout: `/tmp/plan42-worktree3`, branch `feat/dnd-input-registry`, HEAD `5b945fdad7498f350c787a6ee11ece8d46d256c5`.
- Preservation checkout: `/tmp/t7-preserved-20260908`.
- Baseline local main: `5ca92af7c0cf27eecd9e8229ae36630ae43fb910`. This is the local baseline, not a claim about the current remote main.
- T7 original history: `preserve/t7-touch-original-20260908` points at the original T7 HEAD.
- Registry-inclusive history: `preserve/t7-registry-original-20260908` starts at the original registry HEAD; this evidence commit adds only preservation artifacts.
- Automatic registry bridge commit: `ccd858379f9d48a6eef20d4c24876bf7f6510752` (touch enabled by default, bridge creation/destruction, target ordering).

`touch_drag.js` Git blob is `bf4316284db45aca058f854857d5b11912956b0d`; local main blob is `b1efb7f82fb39e2566b74606f9c68c379a98c0b4`. They differ in this environment. The final touch handler, touch bridge and touch bridge test are identical between the two source HEADs.

## Relevant changed files

Paths relative to `engines/collavre/app/javascript/`:

- `lib/touch_drag.js`: live targets, positional hit metadata, refresh after expansion, edge scrolling, cancellation cleanup.
- `lib/__tests__/touch_drag_targets.test.js`: synthetic touch event tests.
- `lib/dnd/touch_bridge.js`: delegated registry bridge.
- `lib/dnd/__tests__/touch_bridge.test.js`: bridge tests.
- `lib/dnd/registry.js`: automatic bridge, live discovery and registry lifecycle.
- `lib/dnd/__tests__/registry.test.js`: registry tests in the registry-inclusive history.

The registry-inclusive branch preserves its complete existing history, including T3 changes. It is an archive, not a newly integrated or release-ready PR. The original T7 checkout has an untracked registry dependency; its exact bytes are retained as `worktree5-untracked-registry.js.snapshot`, separately from the automatically enabled registry version.

## Historical validation

Full relevant historical command outputs and timestamps are in `historical-test-results.json`. These are prior runs, not new test results:

- T7 11:33:00 UTC: touch handler suites, 2 suites / 8 tests passed.
- T7 11:39:16 UTC: touch handler and bridge, 3 suites / 19 tests passed.
- T7 11:40:07 UTC: bridge, 14 tests passed; bridge coverage 100% statements/branches/functions/lines at that revision.
- T7 11:43:57 UTC: latest recorded bridge-only run, 19 tests passed.
- Registry 11:43:00 UTC: DnD suites plus live-target tests, 4 suites / 32 tests passed; registry/preview coverage 100% at that revision.

The final T7 commit at 11:45:32 adds missing-coordinate guards. The extracted record does not establish a test rerun after that commit; earlier coverage must not be treated as final-HEAD coverage. No new tests or fixes were added for this archival task.

## Patch artifacts

- `t7-original.patch`: exact local-main-to-T7 diff for the four committed T7 files.
- `registry-auto-touch-bridge.patch`: original automatic-bridge commit as a mail patch; requires its original registry/T7 prerequisites.
- `worktree5-untracked-registry.js.snapshot`: original untracked supporting file, unmodified.
- `SHA256SUMS`: SHA-256 of the preservation artifacts.

- `registry-inclusive-original.patch`: complete original registry checkout diff against the recorded local main, including prerequisites and T3 changes.

Git push was attempted but failed because this shell has no HTTPS GitHub credentials (`fatal: could not read Username`). Attachment to Creative 20904 was also attempted and rejected with `No write permission on Creative`. Artifacts remain available in this preservation checkout; remote delivery is pending.

Archive validation: both complete patches passed `git apply --reverse --check` against the preserved registry checkout. Source worktree status still shows the same original untracked files.
