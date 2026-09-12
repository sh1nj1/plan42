# PR3b: Workflow rule editor

PR3a is merged. This change exposes its schema through an editor without changing
routing defaults, running `emits`, or removing agent routing expressions.

- [x] Add authorized workflow read, rule create, and rule update endpoints with
  parser diagnostics, permission warnings, and vocabulary-backed options.
- [x] Review the server contract against requirements, then review code quality.
- [x] Add the workflow panel to the creative edit page, with event, handler,
  agent, source, author, body phrase, and advanced Liquid controls. Use existing
  tree ordering, explain pin scope, and preserve advisory/future fields on save.
- [x] Verify create, save, reload, error handling, read-only access, and EN/KO text
  in controller, JavaScript, and focused browser tests.
- [x] Complete independent specification and code reviews; address findings.
- [x] Run changed-area regression tests, changed executable-line coverage,
  RuboCop, stylelint, and complexity checks.
- [x] Commit with an English Conventional Commit; push with `--no-verify`, open
  an English ready-for-review PR, attach its topic monitor, and report to Soonoh.

## API and permissions

GET `/creatives/:id/workflow` reads active direct rules in tree order, along with
validation results and vocabulary options. PATCH `/creatives/:id/workflow_rule`
updates one rule. POST on the workflow's `/workflow_rule` creates a direct rule
so the editor supports the required create/save/reload flow. Mutations require
admin permission and preserve unrelated metadata. Fatal validation returns 422;
advisory diagnostics remain visible and do not block saving.

A workflow can be marked using the existing metadata editor (`kind: workflow`).
The panel does not add a second reordering interface. Agent response permission
is checked at the workflow for editor feedback, and the scope explanation makes
clear that each pinned target's actual permissions still govern dispatch.

## Scope

No migrations, new environment variables, event emission, or rollout-mode changes.
All user-visible text is localized in English and Korean. Work happens in an
isolated worktree; tests run from the host root and cover changed areas only.
