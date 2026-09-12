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
continue editing while background permission jobs are queued.
Invalid rules show parser errors and cannot be saved until repaired. Advisory
warnings, including unknown condition keys and unknown `emits`, do not block
saving. The editor preserves fields outside its controls. Advanced rule data can repair
malformed values that the structured fields cannot express; changes are applied
explicitly before saving. It does not emit events.

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
