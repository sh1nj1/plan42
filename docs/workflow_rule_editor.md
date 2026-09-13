# Workflow rule editor

Workflow creatives own ordered routing rules. Their immediate children are rules;
descendants of a rule are notes. The editor uses the same schema as the routing
resolver and does not change routing mode when a rule is saved.

## Open and edit

1. Create a creative and set `kind: workflow` in its existing metadata editor.
2. Open that workflow's tree and follow the workflow editor link.
3. Add a titled rule, choose an event and handler, and save. Agent handlers can
   select several responders. Human and none handlers both silence AI routing.
4. Add optional conditions: source, whether the author is an agent, body phrases,
   and Liquid under Advanced. All configured conditions must match; source and
   body phrase lists each match any item. Liquid has no `agent` binding.
5. Reload to verify the saved rule. Use the existing tree to rename or reorder
   rules. The first matching rule wins; a matched silent or ineligible handler
   never falls through to another rule or the agent defaults.

Reading requires creative access; creating and updating rules require admin
permission. A collaborator with write permission can inspect the panel but cannot save.
New rules retain the workflow owner's ownership; creation history records the
administrator who created them. Each rule's controls reflect its own permissions.
Creation initializes inherited permissions before returning, so collaborators can
continue editing while background permission jobs are queued. It then enqueues the
standard creation broadcast for subscribed creative trees.
Invalid rules show parser errors and cannot be saved until repaired. The editor
checks Liquid syntax without rendering it; malformed conditions return 422 and
leave the stored rule unchanged. Both shorthand conditions and full Liquid
templates are supported. Advisory
warnings, including unknown condition keys and unknown `emits`, do not block
saving. The editor preserves fields outside its controls. Advanced rule data can repair
malformed values that the structured fields cannot express; changes are applied
explicitly before saving. Saving or previewing rules never executes them.

## Scope and rollout

Pin the workflow as a creative context to apply it in that creative's subtree.
Own pins precede inherited pins; disabled context pins remove the workflow from
that scope. Agent permission hints in the editor refer to the workflow creative.
Each actual target creative's permissions still decide whether an agent can
respond; pinning a workflow grants no permissions.

The matching policy defaults to `shadow`, which evaluates rules and logs a
comparison while existing agent routing expressions determine dispatch. Review
shadow differences before using the admin orchestration policy editor to enable
`workflow_routing: "on"` at the intended creative or topic scope. Use quoted mode
strings in YAML. `"off"` skips workflows; a workflow miss in `"on"` mode retains
the agent defaults. Topic primary agents, mentions, and review authors retain
their higher routing precedence.

## Execution and recovery

In `on`, set `emits` in Advanced rule data to a registered event, such as
`workflow_step_completed`. An agent rule publishes one child after every admitted
responder completes with a usable public reply. The child preserves correlation,
advances depth, and uses the reply from the lowest admitted agent ID as its anchor.
Generated text is not parsed again for explicit mentions. `comment_created` can
also be emitted as a logical routing event without creating another comment.

Human handlers create a generic, linked action-needed entry in the target
creative owner's Inbox and stop. None handlers ignore the event. Neither emits;
the editor warns when they have an `emits` value. Login cards, review-only updates
without an anchor, failed tasks and unusable replies stop continuation. A separate
login replay or manual retry cannot reopen a sealed workflow; send a new message.

Each scope-local chain allows relative depth 8, absolute depth 64, 16 admitted
agent tasks and 16 rule executions. A rule can run once per chain. Ordinary
mentions, topic primary agents and expression fallback retain their existing
routing and limits. Default `shadow`, `off`, and settings saves produce no workflow
execution, child event or handoff notice.

Executions freeze their rule and admitted responders. Durable outboxes and a
recurring workflow sweep recover scheduling/publication gaps with at most three
attempts. Drop Trigger redelivery preserves its serialized job ID receipt; new
jobs, cron invocations and deliberate restarts can create separate handoffs.
Current scope, mode and permissions are rechecked. A topic move can stop pending
work without transferring its chain, and access restoration does not reopen it.

Workflow push is best effort. The Inbox entry survives push failure. Only an
explicitly disabled notification preference suppresses push; unset permits it.
A queue attempt has 30 minutes to start, followed by a five-minute transport lease,
with three total attempts. A lost job or pre-enqueue crash therefore waits for
queue expiry plus sweep and recovery delay. Repeated queue delays can exhaust
attempts with no transport calls, and a crash after transport acceptance can
produce a duplicate push. These deadlines are not delivery or recovery SLAs.

For diagnostics, inspect `Collavre::Workflow::Chain` by `correlation_id` and scope,
its `executions`, their `reason`, and `outboxes`. Tasks carry
`workflow_execution_id`; ordinary restored dispatches and separate login replays
do not inherit that reference. Execution logs include IDs, depths and reason
codes without copying message bodies.

## API

- `GET /creatives/:workflow_id/workflow`: ordered visible active direct rules,
  parser diagnostics, vocabulary options, agent options, and management state.
- `POST /creatives/:workflow_id/workflow_rule`: `{ description, workflow_rule }`
  creates one rule and returns 201.
- `PATCH /creatives/:rule_id/workflow_rule`: `{ workflow_rule }` replaces the
  rule payload while retaining its title and unrelated metadata, returning 200.

Fatal validation returns 422; insufficient permissions return 403. Workflow
links resolve to their origin. A direct linked child with its own rule metadata
is interpreted and updated on that direct row, matching the routing resolver.
