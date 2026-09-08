# T6 preservation — 2026-09-08

No implementation was recreated. Original checkouts were not reset, cleaned, or deleted.

- Original checkout: `/tmp/plan42-worktree4`, branch `feat/dnd-move-menu`.
- Base: `5ca92af7c0cf27eecd9e8229ae36630ae43fb910`.
- Original commits: `96ba48e79d9f7e5323b43d97f84f75544a6da7ec`, `73328c5f6007981b4602c7ee650651b9c852d83b`.
- Exact original branch: `preserve/t6-original-20260908`.
- Later uncommitted controller and test copied byte-for-byte from `/tmp/plan42-worktree1` to `preserve/t6-session-20260908`.
- Session: `rollout-2026-09-08T11-29-39-01a080c7-e688-71d2-878e-ff2b985f4ba8.jsonl`.

## Historical validation (not rerun)

Original session: 51 tests passed; controller coverage 100%; esbuild passed.
Later executeMoveCommand contract update: 3 suites / 52 tests passed; controller statements, branches, functions, and lines 100%.
Raw historical command outputs are in `historical-tests.txt`.
Ruby checks were not run because Ruby was unavailable. Historical CSS lint reported two vendor-prefix errors. Helper complexity ratchet was not verified.

## Dependencies and scope

This is a preservation snapshot, not a standalone integration or release branch.
Original T6 imports executeCreativeMove; the later controller imports executeMoveCommand and expects ok/status results. The corresponding T2/shared picker integration remains a separate dependency.
The original untracked move_command.js was a test-only copy, deliberately excluded from original commits; its bytes are retained as `test-only-move-command.js.txt`.
`integration-locales.patch` preserves the later adjacent EN/KO partial_drop additions without applying unrelated integration changes.

## Original changed files

```
engines/collavre/app/assets/stylesheets/collavre/modal_dialog.css
engines/collavre/app/helpers/collavre/creative_move_helper.rb
engines/collavre/app/helpers/collavre/creatives_helper.rb
engines/collavre/app/javascript/controllers/__tests__/creative_move_controller.test.js
engines/collavre/app/javascript/controllers/__tests__/link_creative_controller.test.js
engines/collavre/app/javascript/controllers/creative_move_controller.js
engines/collavre/app/javascript/controllers/index.js
engines/collavre/app/views/collavre/shared/_creative_move_modal.html.erb
engines/collavre/app/views/collavre/shared/_link_creative_modal.html.erb
engines/collavre/config/locales/dnd.en.yml
engines/collavre/config/locales/dnd.ko.yml
engines/collavre/test/helpers/creative_move_helper_test.rb
```

## Later controller snapshot SHA-256

- `engines/collavre/app/javascript/controllers/creative_move_controller.js`: `817a8fb5a1d2885ee49fc270c0f3ab10bc19d2a168b9f75e9df7f8872c70d0a2`
- `engines/collavre/app/javascript/controllers/__tests__/creative_move_controller.test.js`: `a8f35c9cc7d040c6659c37dedfc562252ae6a4236ab83c7b5586eab8fd20b44d`
