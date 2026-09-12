# Workflow Creative routing with agent defaults — PR3a

## Approved design

Workflow rules express who should handle an event in a creative subtree. An
agent's `routing_expression` remains its reusable default participation rule.
The previously proposed PR5 removal of that column and editor is withdrawn.

Precedence: review author → mention → topic primary agent → workflow → agent
routing. Only a workflow **miss** falls back to agent routing. A matched rule
is final, including `human`, `none`, and agents that lack permission or are no
longer eligible. The default mode is `shadow`: calculate and compare workflow
results, while the existing agent tier still decides actual routing.

PR3a implements parsing and routing only. PR3b adds the editor after schema
review. Event emission, budgets, and tracing remain PR4. `emits` is stored and
validated for advisory diagnostics in PR3a but never executed.

## Contract

- No database migrations or new SQL JSON operators. Use ID-scoped queries and
  Ruby filtering of the existing `creatives.data` column.
- Workflow: `data = { "kind": "workflow" }`.
- Its immediate children with `kind: "workflow_rule"` each hold one rule in
  `data["workflow_rule"]`. Descendants below those children are human notes.
- Rule fields: registered event `on`, optional `when`, required `handler`,
  optional `emits`. Handler types: `agent`, `human`, `none`; agents require a
  nonempty integer `agent_ids` list.
- Conditions AND together. `source` and case-insensitive `body_contains` are
  any-of lists; `author_agent` is boolean; `liquid` is evaluated last, once per
  rule, without an agent binding. A missing envelope cannot match source.
  Envelopes without a source use PR2's explicit `unknown` source sentinel.
- Unknown events, handlers, or malformed structures invalidate a rule.
  Unknown condition keys are ignored with advisory errors; unknown emitted
  events are advisory. Diagnostics are localized in English and Korean.
- Syntactically valid agent IDs are checked for current eligibility at routing
  time. Deleted or unauthorized agents cannot cause expression fall-through.
- Active pins mirror MessageBuilder: effective origin, own pins then inherited
  pins, remove disabled IDs and creative/origin IDs. Archive filters apply to
  both workflows and rules. Child order is `sequence`, then `id`.
- Load all pinned creatives once and all workflow children once. Memoize the
  resolver. Limit valid parsed rules to 200; warn with the discarded count.
- Exclude workflow and rule pins from agent context messages without adding a
  creative-loading query.
- Matching policy `workflow_routing`: `off`, `shadow` (default), or `on`.
  Invalid values become `shadow`. Existing global → Creative → Topic policy
  precedence applies; User policies do not control workflow mode.
- Shadow diagnostics include creative ID, event, workflow IDs, expression IDs,
  agreement, rule count, and correlation ID. Sorted responder IDs determine
  agreement; a miss and empty expression result agree. Workflow failures must
  not interrupt shadow routing. Unexpected failures propagate in `on` mode.
- Existing assignment revalidation is unchanged.

## Execution checklist

Task order resolves dependencies: Creative predicates, Conditions, Rule,
Resolver, policy, then Matcher. Each task uses tests first and a task review.

- [x] Creative predicates and prompt exclusion, including mixed context pins.
- [x] Structured predicates, short-circuiting, missing data, Liquid errors.
- [x] Immutable rule value, fatal/advisory parser, EN/KO diagnostics.
- [x] Ordered resolver, inheritance, disabled pins, archives, cycles, cap.
- [x] Matching policy defaults, precedence, invalid values, ignored User scope.
- [x] Matcher first-match tier, exclusive decisions, existing routing fallback,
      shadow error isolation and comparison, assignment compatibility.
- [x] Affected suites pass; changed executable lines have 100% coverage.
- [x] RuboCop and complexity ratchet pass; final branch review is resolved.
- [x] Push with `--no-verify` and open an English ready-for-review PR:
      https://github.com/sh1nj1/plan42/pull/1679

## Verification and rollout

### PR review follow-up: preserve matching policies in the admin editor

- [x] Reproduce rejected matching YAML and lost policies on unrelated saves.
- [x] Include matching in admin serialization, validation, and shadow defaults.
- [x] Verify global modes and Creative/Topic overrides survive a YAML round trip.
- [x] Preserve the effective merged config when multiple global matching policies
      exist, using the resolver's priority order and shallow merge semantics.
- [x] Complete affected tests, changed-line coverage, lint, complexity, and review.
- [x] Push the fix to PR #1679 and confirm the topic monitor remains attached.

Validation: 27 tests / 133 assertions passed; this follow-up covers 5/5
changed executable Ruby lines (100%). Six regression tests failed before their
fixes. RuboCop passed across 1,420 files; the complexity ratchet reported no
growth. Independent specification and quality review has no remaining findings.

### PR review follow-up: A2A source before selection

- [x] Reproduce source-filtered workflow misses in `topic_message_create`.
- [x] Stamp one A2A envelope before both selection passes and reuse it at
      dispatch, preserving parent causality and post-commit reselection.
- [x] Verify exclusive agent/silence decisions, self-route rejection, envelope
      identity, related tests, changed-line coverage, lint, and complexity.
- [x] Complete independent specification and code quality reviews.
- [x] Push the fix to PR #1679 (`dfc44923d`).

Review validation: 568 tests / 1,602 assertions passed; changed executable Ruby
coverage 230/230 (100%). RuboCop passed across 1,419 files and the complexity
ratchet reported no growth. Source-routing regressions failed before the fix.

Run from the host root:

```sh
bin/rails test engines/collavre/test/services/collavre/workflow/
bin/rails test engines/collavre/test/services/collavre/orchestration/
bin/rails test engines/collavre/test/services/collavre/ai_agent/message_builder_test.rb
bin/rails test engines/collavre/test/models/collavre/creative_workflow_test.rb
./bin/rubocop -a
bin/complexity_check
```

Preserve existing orchestration assertions. Add tests for all new paths and
measure the changed executable lines using SimpleCov (`COVERAGE=1`). This is a
backend PR: no UI/system behavior is added. Follow the user's scoped-test rule.

Start with shadow traffic in the intended creative/topic. Inspect mismatches
and confirm each intended exclusive decision before applying a scoped
`matching` policy with `workflow_routing: "on"`. Matching rules may deliberately
differ from agent defaults, so agreement is evidence for review, not a universal
requirement. A missing rule always falls back to agent routing. Roll back that
scope to `shadow` or `off` when needed; a narrower policy overrides a global one.

Use the existing admin orchestration YAML editor to manage `matching` alongside
other policies. Keep mode values quoted (`"off"`, `"shadow"`, `"on"`) so YAML
does not interpret `on` or `off` as booleans. For example:

```yaml
matching:
  global:
    workflow_routing: "shadow"
  overrides:
    - scope_type: Creative
      scope_id: 123
      config:
        workflow_routing: "on"
      priority: 50
```
