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
  rule, without an agent binding. Missing source metadata cannot match source.
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

- [ ] Creative predicates and prompt exclusion, including mixed context pins.
- [ ] Structured predicates, short-circuiting, missing data, Liquid errors.
- [ ] Immutable rule value, fatal/advisory parser, EN/KO diagnostics.
- [ ] Ordered resolver, inheritance, disabled pins, archives, cycles, cap.
- [ ] Matching policy defaults, precedence, invalid values, ignored User scope.
- [ ] Matcher first-match tier, exclusive decisions, existing routing fallback,
      shadow error isolation and comparison, assignment compatibility.
- [ ] Affected suites pass; changed executable lines have 100% coverage.
- [ ] RuboCop and complexity ratchet pass; final branch review is resolved.
- [ ] Push with `--no-verify` and open an English ready-for-review PR.

## Verification and rollout

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
