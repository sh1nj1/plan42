# Creative types

The inline editor's footer offers General, Workflow and an explicit custom-type
addition. It shares the searchable popup with the agent model picker. Search text
is not submitted: selecting an option or choosing Add stages a type alongside the
body for the existing autosave/close save. Escape or Tab dismisses an uncommitted
search. Closing the editor flushes edits, as before; it is not a discard action.
Failed saves retain both inputs for correction and retry. The confirmed Workflow
selection exposes Edit rules, which opens the existing workflow editor.

## Storage and authorization

`creative[creative_type]` is a dedicated virtual attribute on create/update;
`data.kind` remains protected from generic metadata writes. General is the empty
string and removes the kind key. Strings are normalized with Unicode NFKC,
leading/trailing whitespace removal, whitespace collapse, and lowercasing. The
canonical value must be at most 64 characters without control characters. Custom
values are classifications only. Canonically equal values are the same type; no
separate global registry is created. Existing custom values remain visible when
reopening their creative. Arbitrary JSON and null are rejected.

Type updates require write access to the actual placement and origin. A change
across the Workflow boundary additionally requires admin permission, matching
rule management. The origin is locked while the body/type request is applied;
a rejected request rolls back linked placement changes as well. Archived and
externally managed creatives cannot change type.

## Known discriminators and reserved transitions

The source inventory across all engines identifies these Creative `data.kind`
values (as of the base commit e00fe7a5f):

| Value | Used by | Transition policy |
| --- | --- | --- |
| absent | Ordinary creative | General selection |
| `inbox` | `Creative.inbox_for`, `inbox?`, inbox scope and system topics | No entry or exit through the selector |
| `workflow` | Workflow resolver, editor and routing policies | Admin-only entry/exit; default shadow behavior unchanged |
| `workflow_rule` | `Workflow::Rule`, direct-child rule endpoints | No entry or exit through the selector; dedicated endpoint validates payload and parent |

Topic `system_kind` and message/drag payload `kind` are separate discriminators.
The selector cannot manufacture a rule, even directly below a workflow. Existing
system types permit unchanged body edits. Generic metadata protections remain.

Any actual type change is refused if `workflow` or `workflow_rule` metadata keys
exist (even empty/invalid), or if a direct workflow-rule child exists, including
archived rules. This also prevents activating dormant configuration. No settings,
rules, execution history or receipts are deleted. Moving/removing settings is a
separate explicit action; there is no implicit cleanup or conversion operation.

Changing types/settings does not publish workflow events. Existing comment/task
publication, default shadow mode, unmatched `on` fallback to `routing_expression`,
and terminal matched human/none/ineligible routing remain unchanged. The PR5
removal/seed plan and the existing task 21056 duration-test failure are excluded.
