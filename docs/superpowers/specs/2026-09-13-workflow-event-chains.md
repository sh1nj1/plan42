# PR4: workflow events and chained execution

Status: implementation proposal. The emission timing question has been sent to
the product owner. Vrex recommends completion-based emission in review topic
19327; the cross-post in topic 19326 is a reviewer report, not a separate product
approval. The semantics and limits below are new PR4 proposals, not approvals
inherited from PR3. This document is reviewable before runtime changes are made.

## Scope and invariants

- Default `shadow` remains unchanged. `off` does not resolve rules. `shadow`
  resolves and logs only: neither mode writes workflow executions, emits workflow
  events, or sends workflow notifications. Ordinary comment notifications remain.
- Review author, explicit mentions, and topic primary agent retain their priority.
  Only a decision made by the workflow tier may start a workflow execution.
- In `on`, the first matching rule owns the outcome. A miss retains
  `routing_expression`. Human, none, and ineligible agent matches never fall
  through, including when an execution is blocked, fails, or exhausts its budget.
- Selecting responders is read-only. `select`/`prepare_selection`, shadow
  comparison, rule creation, and rule saves cannot execute workflows.
- A normal human comment dispatch starts a fresh root correlation, including a
  reply in a topic with an existing workflow. It does not join that earlier chain.
- `routing_expression` columns, UI, migrations and default seeds are outside PR4.
  PR3's no-migration constraint covered PR3. PR4 needs durable execution state;
  new migrations belong to the core engine.

## Handler and emission contract

| Handler | Work | `emits` |
| --- | --- | --- |
| agent | Existing Matcher eligibility, Arbiter floor selection and Scheduler admission determine the responders. Persist that selected set once. | After every admitted responder has successfully completed and its reply is committed, create one child event for the rule execution. Never once per agent. |
| human | Silence AI; durably create one action-needed inbox notice for the eligible target creative owner. | Stop at the human handoff. No automatic emission; there is no human completion API in PR4. Show a warning if `emits` is configured. |
| none | Explicit terminal ignore; no tasks or notifications. | Never emit, including when configured. Show a warning. |

Agent success requires `done`, a committed non-private, non-placeholder,
nonempty reply linked to that task in the same creative/topic, and no recorded
provider handoff failure. Reuse the existing finalized-response and replay
completion evidence in `Task::ReplayLoopCompletion`; do not create a competing
definition of provider success. Its `unsuccessful_loop_response?` alone is not a
positive success predicate: it explicitly excludes `engine_login` turns.
PR4 treats an `engine_login` card as `login_required`, never as a successful
reply. Normal authentication/replay remains available, but does not reopen that
terminal workflow execution. Carrying a workflow completion obligation into a
separate login replay task is outside this proposal; a new root event is needed
after authentication. This limitation must be visible in editor/help text.

A successful `review_updated` action without a usable reply anchor is
`completed_no_anchor`: success without emitting. Review routing normally outranks
the workflow tier, so an ordinary review never starts a workflow execution.
This explicit outcome also covers an adapter that completes by updating an
existing reply. Do not manufacture or quote a private anchor to continue it.

Settlement evaluates the following cases in order, after checking that the
execution is still open and its mode, permission and scope remain valid:

| Task evidence | Workflow outcome |
| --- | --- |
| `failed`, `cancelled`, or `escalated` | `task_failed`; no continuation |
| Any status other than `done` | Keep waiting; no success inference from response actions |
| `engine_login` key present, including retryable, replay-completed or abandoned cards | `login_required`; never reopen after separate replay |
| Recorded provider handoff failure (`ended_undelivered?`) | `task_failed`, even if an error reply exists |
| `unsuccessful_loop_response?` | `empty_reply`; no successful finalized response |
| Finalized `review_updated` action with no reply anchor | `completed_no_anchor`; successful terminal outcome without emission |
| Missing reply without that successful review evidence, or empty/placeholder reply | `empty_reply`; never manufacture an anchor |
| Existing reply is private, deleted, moved or outside the task's scope | Stop with `permission_revoked` or `scope_changed`; do not relabel this as successful review completion |
| Finalized response and committed, usable reply | Record responder success; emit only after the full admitted set succeeds |

Keep the adapter for these decisions on `Task` so it can reuse the private
`finalized_response?` and replay predicates without copying their implementations.
`loop_completion_delegated_to_replay?` is a separate private predicate; it is not
called by `unsuccessful_loop_response?`. The explicit login branch above covers
both delegated and abandoned login cards. Existing trigger-loop replay behavior
stays unchanged. In a fan-in, any successful `completed_no_anchor` member makes
the execution non-emitting; another responder's anchor cannot replace its result.

`done` alone is insufficient. `running`, `delegated`,
`pending`, `queued`, and `pending_approval` are not completion. `failed`,
`cancelled`, `escalated`, empty completion or lost/revoked scope stop the execution.
A workflow never approves tools or substitutes a responder.

The fan-in set contains responders actually admitted by Scheduler, not every ID
in the rule. A partially rejected set is recorded explicitly. If no responder is
admitted, stop without emitting. If one admitted responder fails, stop the chain;
already running siblings retain their ordinary task lifecycle but cannot emit a
continuation. A later manual retry of a terminal workflow task does not reopen
its chain: start a new external event for a new attempt.

## Event vocabulary and context

Register `workflow_step_completed` with required `creative`, `comment`, and
`workflow` payload blocks, source `workflow`. Add `workflow` to the supported
source options of registered events that can be emitted. Only registered names
are executable (`Dispatcher` already enforces names through `Vocabulary.fetch`).
Vocabulary required keys and sources are currently advisory/editor metadata;
add explicit payload and source validation at the workflow execution boundary.
Keep unknown `emits` as a save-time advisory for PR3 compatibility;
when execution reaches that edge, persist `unknown_emit` and stop.

`emits` remains a scalar name: one execution has at most one child. No arbitrary
business event names, dynamic vocabulary registration, interpolation, cross-topic
routing, or user-authored arbitrary payloads are introduced. `comment_created`
may be emitted as a logical routing event over the existing reply; it must not
insert a duplicate comment or run comment creation callbacks.

A child uses `Envelope.child` once, and persists the resulting envelope before
queueing it. Retries reuse that same envelope ID, timestamp and body. Preserve
`correlation_id`; set `causation_id` to the input envelope ID, increment `depth`
by one, and set `source` to `workflow`. Never call `Envelope.child` again on retry.
Before every dispatch assert that persisted envelope name, payload event name and
snapshotted emits agree. A mismatch stops as `invalid_envelope`; otherwise the
existing dispatcher would silently create another child. `occurred_at` is event
creation time, not enqueue or provider-start time. Liquid sees this persisted
value on every retry; it must not be presented as a fresh execution timestamp.

Payload (JSON-safe):

```json
{
  "event": {"id": "persisted-child-uuid", "name": "workflow_step_completed",
    "source": "workflow", "correlation_id": "root-uuid",
    "causation_id": "input-uuid", "depth": 1, "occurred_at": "ISO8601"},
  "event_name": "workflow_step_completed",
  "creative": {"id": 123},
  "topic": {"id": 456},
  "comment": {"id": 789, "user_id": 42, "content": "committed reply"},
  "chat": {"content": "committed reply", "mentioned_users": []},
  "workflow": {"execution_id": 10, "rule_id": 20,
    "task_ids": [30, 31], "reply_comment_ids": [789, 790]}
}
```

For fan-in, use the successful reply belonging to the lowest selected agent ID
as the deterministic anchor; include every task/reply ID in `workflow`. Build the
anchor from the current Comment's canonical dispatch payload, not an enumerated
partial copy. Preserve the original initiating workspace principal separately;
a generated reply cannot switch CLI workspace credentials to the agent creator.
Rebuild sender from the new reply author. Do not inherit root mentions, review
metadata, replay/login claims, drop-trigger controls or scheduling overrides.
Do not parse generated reply text as a fresh explicit mention; the empty mention
list makes the next event use ambient routing. Primary-agent precedence still
applies. Source-based rules can distinguish workflow continuation from callbacks.

## Durable state and idempotency

Introduce engine-owned workflow chain and execution records, plus a nullable
indexed execution reference on tasks. Normal tasks retain a null reference.

- Chain identity is the envelope correlation ID and fixed creative/topic scope.
  Enforce a composite unique key `(correlation_id, creative_id, topic_id)`.
  Correlation alone is tracing data, never permission or chain membership.
  A workflow outbox child must remain in its recorded chain scope; changing its
  scope fails closed. An ordinary A2A event targeting another topic is outside
  the originating chain and retains normal routing. If it matches a workflow
  there, it may start a separate scope-local chain with its own `root_depth` and
  budgets, preserving the envelope correlation and absolute depth. This is a new
  proposed scope policy; PR4 does not impose a global cross-topic task quota.
- Unique execution identity is `(chain_id, input_event_id)`. Persist the winning
  rule snapshot (JSON `data["workflow_rule"]` plus rule creative ID, not a Ruby
  Rule object), selected responders, admission outcome, input envelope and
  context. Rule edits cannot alter an in-flight execution's configured `emits`.
- Unique task identity is `(workflow_execution_id, agent_id)`. Enqueue retries
  may deliver another job but cannot create another workflow task for that agent.
- Completion seals an execution and reserves its child in one primary-database
  transaction under the chain row lock. Unique child identity is its parent
  execution. Budget reservation and child insertion commit together.
- Use a durable outbox state for agent scheduling and event dispatch. Queue writes
  are after commit. A periodic recovery job retries pending rows, including the
  crash gap between DB commit and enqueue. Concurrent recovery workers claim with
  a token/lease and conditional updates. Retry uses the persisted envelope.
- Agent provider invocation is not claimed to be exactly once across process
  crashes. Existing task recovery governs a started provider call; PR4 does not
  blindly run a terminal or already-started workflow task again.
- If scheduling fails after some jobs were enqueued, retry only missing durable
  admissions. Already admitted tasks keep their identity and frozen fan-in set.
  Do not re-run Arbiter rotation or grow the selected set on retry.
- Infrastructure retries use 3 attempts, followed by a recorded terminal failure.
  A claimed worker has a 5-minute lease; recovery inspects durable task/execution
  state before reclaiming. No generic recursive Ruby dispatch call stack.

### Producer identity and dispatch acknowledgement

There are five registered producer sources, not five automatic root paths: A2A
normally carries a parent envelope. The following map describes existing code
and the proposed PR4 guarantee separately. There is no existing persisted trigger
run ID or cron occurrence ID to reuse.

| Producer | Existing delivery behavior | PR4 identity contract |
| --- | --- | --- |
| `Comment#dispatch_to_orchestration` / `comment_callback` | `after_create_commit`, normally one call for a newly created human comment; no parent | Fresh root. No callback-specific receipt. A producer that creates another comment on retry creates another invocation; PR4 does not deduplicate comment creation. |
| `DropTriggerJob#dispatch_trigger` / `drop_trigger` | Reuses a found trigger comment; `retry_on DispatchFailedError, attempts: 3`; task JSON scan cannot acknowledge human/none | For a workflow-owned decision, a new durable receipt keyed by `(source, event_name, ActiveJob job_id)` stores the first envelope, anchor scope and execution/result. The same serialized job's retries/redeliveries reuse it. |
| `TriggerActionCommand#post_restart_trigger` / `trigger_restart` | Creates a new comment with `skip_dispatch: true`, then explicitly dispatches it; no automatic retry in this command | A deliberate restart is a fresh invocation. No command receipt or HTTP idempotency guarantee in PR4. Reusing a supplied persisted envelope is deduplicated at workflow execution only. |
| `CronActionJob` / `cron` | Each `perform` creates a comment and dispatches an inline payload, without a parent | No occurrence/comment-creation deduplication in PR4. A repeat `perform` can create a separate root and notice. A preserved envelope deduplicates only execution of that envelope. |
| `A2aDispatcher` and `TopicMessageCreateService` / `a2a` | Reply mentions derive a child from the task envelope; the topic tool constructs one child and uses it for that call | Preserve existing parent propagation. Separate tool calls and reconstructed A2A children are distinct deliveries; no new exactly-once A2A guarantee. |

The Drop Trigger receipt is new core-engine state in task 21053, not an assumed
existing mechanism. `job_id` is the serialized ActiveJob identifier, never a
queue-provider ID or the retry attempt count; add a serialization/retry test.
A separately enqueued job has a new ID and is a separate invocation even if its
arguments or anchor match. This does not deduplicate independent duplicate job
creation. Do not key a deliberate restart by comment text or mutable loop state.

Resolve workflow ownership without effects, then atomically persist/claim the
Drop Trigger receipt, its envelope and execution before notification/task effects.
On redelivery, consult an existing receipt before the old `task_exists_for?`
scan and before re-selection. Reuse the frozen selection and current safety
revalidation; concurrent contenders use the receipt's database unique constraint.
The first committed anchor remains authoritative: a deleted/moved/private anchor
stops the receipt, and must not be replaced with a newly found comment. No
receipt is created for ordinary routing or in off/shadow. An existing receipt
is still recognized after a mode change and stopped without effects, so a later
re-enable cannot turn its redelivery into a new root. Existing ordinary trigger
task detection remains outside the new workflow deduplication guarantee.

Introduce an opt-in `dispatch_with_outcome` API through Dispatcher and
AgentOrchestrator. Its result has `agents`, `workflow_execution_id`,
`workflow_handled?`, and `reason`; the existing `dispatch` API remains an array of
real agents. Never insert a sentinel or execution record into that array.
Both APIs delegate to the same execution path; the wrapper must not dispatch
twice. Selection preview still returns no runtime acknowledgement or effects.

`workflow_handled?` means a durable workflow-owned outcome exists: admitted work,
human/none, ineligible/blocked, or a previously recorded outcome all acknowledge
the producer even with zero agents. It does not mean an agent succeeded or a
push was delivered. Persistence failure before ownership commits is retryable;
once ownership commits, its outbox owns infrastructure recovery. Update
`DropTriggerJob` to raise `DispatchFailedError` only when there is neither a
workflow acknowledgement nor an ordinary scheduled/handled agent. A missing or
rejected ordinary route keeps its existing retry behavior. `TriggerActionCommand`
may keep the array API; its `size` log must continue counting real agents only.

The default Drop Trigger comment contains an explicit agent mention and its new
topic has a primary agent. Those tiers normally preempt workflow. The human/none
retry regression must arrange a reused trigger anchor with no effective mention
and no primary assignment, then separately prove default priority is unchanged.
Do not claim that every existing Drop Trigger currently reaches human/none.

Queue acceptance is not handler completion. PostgreSQL row locks and unique
indexes are the concurrency authority; SQLite tests also exercise database
constraints. `Rails.cache`, process-local sets, or scans over task JSON alone are
not sufficient for deduplication or budget accounting.

## Bounds and termination

Proposed fixed PR4 defaults (new decisions, not previously approved):

- Maximum relative workflow depth: **8**. Persist `root_depth` at the first
  workflow admission and require `envelope.depth - root_depth <= 8`. Preserve
  absolute envelope depth; a managed event at absolute depth **64** cannot create
  depth 65. Relative depth 8 may run but cannot create relative depth 9.
- Maximum admitted workflow-handler agent tasks per scope-local chain: **16**, shared
  across workflow fan-out and steps. Reserve the entire selected/admitted set atomically before enqueue;
  if it does not fit, stop the step instead of truncating responders.
- Maximum workflow executions per chain: **16**, counting agent, human and none
  decisions. Repeated deliveries and blocked duplicates consume no additional
  budget. Existing upstream depth remains traceable and is never reset in the
  envelope. The step budget bounds multiple workflow entries sharing a correlation;
  it would be redundant for a purely linear scalar-emits chain. It counts only
  actual workflow rule executions, not ordinary routing decisions.
- The same rule creative ID may execute only once per chain. Encountering it
  again records `cycle`, including A -> B -> A and self-emission. New root events
  may legitimately run the same rule again.
- At workflow admission/publication, invalid negative/malformed depth, an
  inconsistent persisted chain/envelope, unknown event, missing anchor, or a
  deleted/private/moved anchor stop without fallback. This is not a global
  pre-Matcher scope gate for ordinary A2A routing.

These are workflow budgets, not a new global conversation quota. A2A mentions,
review, primary-agent routing and expression fallback retain their existing
admission and LoopBreaker policies; they do not consume workflow task budget or
emit a matched rule's continuation. An emitted event that falls through to normal
routing remains a normal dispatch. Enforce workflow publication bounds before
publishing the edge, not by refusing its later fallback result. If a later event
in the same correlation and scope actually matches a workflow rule, its execution shares
the workflow budget and rule-cycle guard. A2aDispatcher is a distinct existing
handoff path; PR4 does not claim to bound every ordinary A2A descendant or provide
exactly-once delivery for that pre-existing path. This narrowed scope preserves
existing routing rather than turning a workflow counter into a conversation stop.

### A2A ordering and failure boundary

In-process `AiAgentService#call` dispatches reply mentions before `AiAgentJob`
transitions to `done`. External `/agent/reply` finalizes the task and fires
completion callbacks before dispatching mentions. PR4 does not reorder either
transport. Explicit reply mentions win above workflow and cannot reserve its
budget, repeat its rule, or emit its configured child. With one workflow task
slot left, A2A admission therefore cannot take that slot ahead of `emits` in
either transport. Ordinary scheduler capacity and LoopBreaker can still affect
scheduling order; this is not a guarantee of identical wall-clock task ordering.

Do not add a workflow rejection gate in `A2aDispatcher`, before or inside its
`rescue StandardError`. Its existing interaction-before-dispatch behavior stays
unchanged. New workflow denials are persisted at the workflow execution boundary
and returned as typed outcomes, not communicated by an exception swallowed by
that rescue. Workflow `emits` does not call A2aDispatcher or record an A2A
interaction. No new workflow-budget rejection notice is attached to a reply
mention, because PR4 never rejects that mention on workflow-budget grounds.

If an in-process parent fails after sending A2A, its already-dispatched ordinary
A2A descendants retain their existing lifecycle. Their tasks have no workflow
execution reference, take no workflow reservations to refund, and cannot settle
or emit the failed parent's configured continuation. An independent ambient
event that later matches workflow is subject to its own scope-local admission;
PR4 does not cancel all ordinary descendants sharing a correlation. Within the
same chain, admitted reservations are not refunded and sealed executions never
reopen. The existing in-process `review_flow` skip remains: do not synthesize an
A2A handoff for a review-only completion with no anchor.

Record terminal reason codes: `completed`, `human_handoff`, `ignored`,
`no_eligible_agent`, `scheduler_rejected`, `task_failed`, `empty_reply`,
`permission_revoked`, `scope_changed`, `routing_disabled`, `unknown_emit`,
`depth_exceeded`, `task_budget_exhausted`, `step_budget_exhausted`, `cycle`,
`delivery_failed`, `invalid_envelope`, `login_required`, `completed_no_anchor`.
Logs carry IDs, event name, correlation, absolute/relative depth and reason;
never bodies, Liquid source, credentials or exception messages containing them.

## Mode, permission and queue revalidation

Before admission, notification persistence and child publication, resolve the
current mode and verify active creative/topic and current scope. Switching to
`off` or `shadow` stops pending workflow effects; re-enabling does not replay them.
Already-started tasks retain their lifecycle, but their completions cannot emit
while routing is disabled. Recheck agent access before provider handoff through
the existing assignment/access gate. Rules subsequently archived, unpinned or
made inaccessible stop pending effects; edited rule data stays snapshotted.

Workflow tasks must not be coalesced into ordinary comment tasks or into another
workflow execution. Exclude them on both sides of TaskCoalescer. Promotion keeps
the original anchor and validates that it remains public and in the same scope;
it must not replace an execution's input with the latest unrelated comment.
History-delivery/drop suppression must not swallow a distinct workflow event
merely because its anchor comment was already read.

## Human notification target and privacy

PR4 chooses one explicit responsibility rule: resolve the event target through
`Creative#effective_origin` and use that origin creative's
human owner (not the workflow configuration owner, rule creator, commenter,
mentioned people, all shared users or an arbitrary `agent_ids` value). Recheck
current feedback permission using authoritative permission resolution, and require
that the anchor is public and still in the same creative/topic. If the owner is
absent, an AI user, revoked or otherwise ineligible, record a blocked handoff;
never substitute a recipient or agent.

Persist a localized action-needed notice in that person's Inbox System topic,
linked to the source conversation. Use only a generic localized label and link:
no copied source body and no `quoted_comment` association. The existing private
`create_inbox_comment` helper always attaches a quote and must not be called
unchanged. Dedup key is execution ID plus recipient ID. Resolve the owner once
for the admitted handoff; an ownership change before delivery stops it rather
than sending the same execution to a second person.
Do not include private rule titles or rule content: a target owner may lack read
access to the pinned workflow. The notice is a system-authored comment with
`skip_dispatch`, and must not recursively trigger workflow or regular inbox
notifications. Respect push preferences using the existing push path. Presence
must not suppress the durable action-needed inbox entry.

`PushNotificationJob` currently does not enforce `notifications_enabled` itself.
The column is nullable with no default. Proposed PR4 compatibility policy:
`false` disables workflow push; `true` and `nil` permit it when a device exists.
Do not use a truthiness gate that silently treats every unset preference as an
opt-out. Apply the gate only to workflow notices. Ordinary mention/approval
delivery retains its current behavior, which does not check this column; this
intentional temporary asymmetry is a product proposal, not an existing invariant
or a general notification-settings fix.
The existing push title is Korean in both the FCM v1 and legacy client paths.
Workflow delivery must use a recipient-localized EN/KO title in both paths,
including the title used to calculate the FCM byte budget. A backwards-compatible
optional title argument can preserve existing callers while supplying the
workflow's localized title. Add coverage for both transports and byte fitting;
do not send the workflow notice through a path that ignores the supplied title.

Use the existing Comment notification unique key and delivery table where
possible. One inbox entry is guaranteed per execution/recipient. External push
is best effort and can be delivered more than once if the process dies after
provider acceptance but before acknowledgement; do not advertise exactly-once
push. Recheck permissions before enqueuing a pending push. PR4 has no human
completion button; replying to the source topic is a separate external event.

Separate persistence from queue delivery explicitly: the chain-locked primary DB
transaction inserts the unique inbox comment and a workflow-tagged pending push
delivery, then seals `human_handoff`. No `enqueue_push!`, `perform_later`, or
provider I/O is allowed inside that transaction, including a nested helper that
enqueues after its own inner transaction. `CommentNotificationDelivery#enqueue_push!`
can raise; calling the existing Notifiable helper inside settlement is unsafe.
After outer commit, attempt push queueing independently. Failure records a
pending retry without undoing the inbox comment, execution seal or receipt.

Persist the workflow execution reference and localized title on the delivery.
The existing `CommentPushDeliverySweepJob` must route workflow-tagged rows through
the same adapter as immediate delivery; it must not call the ungated generic
enqueue path for them. Both paths recheck mode, recorded owner, scope, public
anchor, feedback permission and the explicit-false preference. Revalidate again
in the workflow push worker before handing off to `PushNotificationJob` with
the localized title; direct generic queueing must not bypass that final check.
Rows suppressed by a changed policy/permission are terminal delivery outcomes,
not pending rows that replay when access or settings are re-enabled. The durable
inbox entry remains; the sealed execution remains `human_handoff`. Push retry
exhaustion is a delivery failure, never a reason to reopen or relabel execution.
The sweep must inspect pending deliveries even when their executions are sealed.
Use the proposed 3-attempt/5-minute-lease recovery policy separately for delivery;
no external exactly-once guarantee is introduced by those counters.

## Integration map discovered in current code

- `WorkflowRouting#match_by_workflow` currently discards the matched Rule. Expose
  its decision through Matcher/Selection without side effects, in `on` only.
- `AgentOrchestrator#dispatch` returns early for an empty selected set. Handle
  matched human/none before that return; preserve the array compatibility API
  and expose the new typed outcome to `DropTriggerJob#dispatch_trigger`.
- `DropTriggerJob#perform`, `#prepare_trigger`, `#task_exists_for?` and
  `#dispatch_trigger` require the receipt/acknowledgement boundary above.
  `TriggerActionCommand#post_restart_trigger`, `CronActionJob#perform`, and
  `Comment#dispatch_to_orchestration` retain the stated producer limitations.
- `AiAgentService#call`, `AiAgentJob#perform`, `/agent/reply`,
  `A2aDispatcher#dispatch` and `TopicMessageCreateService#agent_envelope` cover
  transport order and cross-topic correlation; ordinary routing has no new
  workflow gate. The topic tool's `reject_unrunnable_self_dispatch!` rejects
  same-topic or certain unprovable self-routes; those are not its allow conditions.
- `SystemEvents::Dispatcher` reuses a same-name envelope. Feed it the persisted
child without `parent:` on retries, or it would generate a fresh child.
- `AiAgentJob#admit_or_defer!` and `AgentOrchestrator#park_waiter` are the two task
  insert doors. Both must enforce the execution/agent unique identity.
- A new task `after_update_commit` settlement hook must use
  `saved_change_to_status?`, then explicitly inspect workflow terminal states.
  Do not reuse `became_terminal?`: its `terminal_status?` excludes `escalated`.
  `TaskClaimService#finalize`
  uses `update_all` and then `fire_completion_callbacks_after_external_claim`;
  this supported escape hatch must run the same workflow settlement hook.
  Also cover `CliProxy::InlineLogin.abandon_replay!` and
  `Task::ReplayLoopCompletion#recheck_abandoned_replays`, which call that escape
  hatch again on already-terminal tasks. Settlement must be idempotent and must
  never reopen a terminal workflow execution. Validate all three callers.
- A recurring settlement/outbox sweep is mandatory because callbacks and queue
  acceptance are not atomic. Scope it to unfinished workflow records.
- `Comment::Notifiable` already has transactional unique inbox insertion and a
  push delivery record, but its recipient policy and private helper cannot be
  called unmodified for human workflow responsibility.
- `CommentNotificationDelivery#enqueue_push!`, `CommentPushDeliverySweepJob`
  and both `PushNotificationJob` transports need the workflow-specific delivery
  adapter, persisted title and outer-commit boundary above.

## Boundary scenarios and acceptance checks

| Scenario | Expected result |
| --- | --- |
| Default shadow or explicit off with matching emits/human | Zero workflow records/events/notices; existing routing and comment notifications unchanged |
| Rule save/create; selection preview; repeated shadow evaluation | Zero runtime effects |
| Two matching rules | Only first owns routing, tasks, notice and emits |
| Workflow miss | Existing routing_expression outcome |
| Human/none/no eligible agent | No fallback, no agent job; only eligible human gets one notice |
| Higher priority review/mention/primary | No workflow execution or emit |
| Two selected agents, one completes | No child yet |
| Both succeed | One child, stable fan-in IDs and deterministic anchor |
| One fails/cancels/returns empty; later manual task retry | Terminal chain, no child or reopened chain |
| Delegated reply; tool approval pause/resume | No emission before committed successful reply; external completion settled too |
| Inline login card ends done; subsequent separate replay succeeds | Login card records login_required, never emits; normal replay does not reopen this workflow |
| review_updated-only successful completion | completed_no_anchor; no manufactured anchor or emit |
| Fan-in includes one review-only success without an anchor | No child, even when another responder has a usable reply |
| escalated transition; repeated external completion callback | Prompt terminal settlement; repeated settlement is a no-op |
| Duplicate delivery/completion; two concurrent workers | One execution, one task per agent, one child and one budget reservation |
| New human reply in a workflow topic | Fresh root correlation; never inherits the earlier workflow budget |
| Drop Trigger human/none with higher-priority tiers absent | Typed acknowledgement with zero agents; no empty-array failure retry |
| Same serialized Drop Trigger job delivered twice/concurrently or retried after receipt commit | One workflow receipt, envelope, execution and owner notice; no re-selection |
| Ordinary default Drop Trigger mention/primary; ordinary no-agent result | Priority preserved; missing ordinary route still follows the existing retry policy |
| Drop Trigger receipt followed by off/shadow and re-enable | Recognize prior delivery, stop pending effects, never create a replacement root |
| Separately enqueued Drop Trigger job, deliberate restart, repeated cron perform, producer creates another comment | Separate invocation can create another root/notice; no universal producer deduplication claim |
| Off/shadow producer calls without a prior receipt | No new workflow receipt or execution |
| Ordinary A2A/primary/fallback after workflow budget exhaustion | Existing admission policy still applies; only new workflow effects stop |
| Reply mentions another agent with one workflow task slot left, in-process versus external reply | A2A does not consume the workflow slot/cycle guard; emits requires successful settlement in both paths |
| In-process parent fails after A2A dispatch | Parent cannot emit; ordinary A2A descendants keep their lifecycle, with no workflow budget reservation/refund |
| topic_message_create to an allowed different topic with the same correlation | Preserve ordinary routing; no source-chain scope denial. A workflow match there uses a separate scoped chain |
| Persisted workflow outbox child changes topic | scope_changed; no cross-topic workflow publication |
| More than 200 resolved rules | Existing Resolver cap/order/warning retained; no new search past the cap during chaining |
| Crash after completion commit or before enqueue | Sweep recovers persisted outbox without new envelope IDs |
| Queue rejects or partially accepts jobs | Bounded retries, no duplicate durable admissions or Arbiter rotation |
| Task budget 15 with two responders | Whole step stops; no partial response truncation |
| Root absolute depth 6 / child relative depth 8 / request for relative depth 9 | Same eight-step allowance as a depth-0 root; relative depth 9 blocked |
| Absolute depth 64 / request for depth 65 | Depth 64 may run if relative bound permits; depth 65 blocked |
| Persisted child name differs from dispatch name | invalid_envelope; never silently create a replacement child |
| A -> A and A -> B -> A | Cycle stops before repeated rule executes |
| Same rule in a new root correlation | Independent execution with fresh budgets |
| Scope/mode/permission/anchor changes while queued | Fail closed with a reason; no new child or notification |
| Owner present, absent, AI, no permission; duplicate delivery | Exactly one eligible human owner inbox entry, otherwise recorded block |
| EN/KO recipient, v1/legacy push, notifications disabled | Localized notice and push title; disabled push leaves the durable inbox notice intact |
| notifications_enabled is nil / true / false | nil and true permit workflow push with devices; only false suppresses it; ordinary notification behavior unchanged |
| Push queue raises after human handoff commit | One sealed execution and inbox entry remain; pending delivery retried independently |
| Crash between handoff commit and push enqueue; concurrent sweep | Recover the same delivery and title using a lease; no duplicate inbox entry or execution |
| Owner/access/mode/preference changes before push sweep or worker handoff | Suppress the pending push durably; generic sweep cannot bypass checks or replay after re-enable |
| Unreadable rule title; private source comment | No rule text leaked; no private source handed off |
| Emitted event over an already-read comment | New workflow task; no history drop or unrelated coalescing |
| Generated reply contains mentions | No replay of root/response textual mentions; primary priority preserved |
| Unknown emits and human/none with emits | Save advisory; no unsupported effect at runtime |

## Sequenced implementation checklist

- [ ] Settle timing choice and review this execution contract (Creative 21052).
- [ ] Add durable execution/outbox state, task identity and event emission (21053).
- [ ] Add atomic chain reservations, cycle detection, settlement recovery and tracing (21054).
- [ ] Add owner handoff and localized editor guidance (21055).
- [ ] Integration, concurrency/permission/failure tests; changed executable-line
  coverage 100%; Rubocop; complexity ratchet; EN/KO key symmetry; independent
  review; seeded preview; ready-for-review PR and topic monitor (21056).

Tasks 21053 and 21054 are development sequencing inside one PR. Do not enable or
deploy a runnable emission path before its minimum atomic budget/depth/cycle
guards are present. Intermediate commits must keep the new execution path inert
until those guards and their regression tests land.

## Design review disposition

Vrex reviewed the initial proposal in Collavre topic 19327. Revisions address
login-card success, review-only completion, escalated callbacks, all three
external completion callers, envelope-name consistency, relative depth, narrowed
workflow budget scope, quote-free human notices and effective-origin ownership.
Names already are enforced by `Vocabulary.fetch`; sources and required blocks
need a new workflow-boundary check. `unsuccessful_loop_response?` is not by itself
a positive success predicate. The revised proposal has not yet received reviewer
sign-off or the product owner's emission-timing answer. No runtime change is
implemented or validated by this document.

### Cross-post review reconciliation

The five blockers in topic 19326 summarize the longer review in topic 19327.
The current proposal addresses them as follows; this is an author disposition,
not a claim that the reviewer has signed off:

| Review item | Specification resolution |
| --- | --- |
| Login card mistaken for success | Explicit ordered `login_required` branch before finalized-response checks; reuse Task evidence rather than negate the unsuccessful predicate |
| Review-only success without an anchor | `completed_no_anchor`, including fan-in termination without a substitute anchor |
| Escalation misses settlement | `saved_change_to_status?` hook plus explicit workflow terminal states |
| Three external callback callers | All three are named in the integration map; settlement is idempotent on already-terminal tasks |
| Inherited absolute depth shortens the budget | Persist `root_depth`; relative limit 8 and separate absolute ceiling 64 |
| Ordinary routing blocked by workflow budgets | Count workflow admissions only; preserve A2A, primary and expression behavior |
| Event validation and retry identity | Existing `Vocabulary.fetch` already rejects unknown names; add workflow source/payload validation and persisted-name equality before dispatch |
| Human ownership and private quotes | `effective_origin` human owner, current feedback permission, public anchor, generic link without quotes |
| Push preference and language | Explicit preference gate and localized title in both transports with byte-budget coverage |

### Second review: producer, A2A and push boundaries

The second report is message 134505 in topic 19327, cross-posted as 134516 in
19326. The following is the author's revised proposal, pending technical review.

| Review item | Revised specification |
| --- | --- |
| A-1: callback receipt misses Drop Trigger empty-result retries | Remove callback-only receipt; add an opt-in typed outcome and acknowledge durable human/none/blocked outcomes without fake agents |
| A-2: unspecified producer keys | List all five source families; add a Drop Trigger receipt using serialized `job_id`; explicitly exclude independent job creation, restart-request and cron-occurrence deduplication |
| A-3: human comments and correlation | New human comment dispatch starts a fresh root, even in an active workflow topic |
| B-1: transport-dependent A2A/emits ordering | Keep transport order; explicit A2A mentions do not share workflow reservations or cycle checks |
| B-2: A2A rescue and interaction order | Add no workflow gate in A2aDispatcher; persist workflow denials at the execution boundary; emits never records an A2A interaction |
| B-3: parent failure after A2A dispatch | Ordinary descendants keep their lifecycle and cannot emit the parent's continuation; no workflow reservation was consumed or refunded by them |
| B-4: correlation crosses topics | Composite scope-local chain identity; ordinary cross-topic A2A is outside the source chain, while persisted workflow children must retain their scope |
| C-1/C-2: nullable preference and notification asymmetry | Propose nil/true as push-enabled, false as disabled, for workflow notices only; preserve ordinary notifications and explicitly identify the product decision |
| C-3: enqueue raises during handoff | Commit inbox entry, pending delivery and execution seal before queue I/O; independent recovery must handle sealed executions and preserve the inbox entry |

Two factual qualifications matter when implementing the regression fixtures:

- `TriggerActionCommand#post_restart_trigger` creates a new comment before its
  explicit dispatch; it does not redispatch an old comment in the inspected code.
  `CronActionJob` also creates a comment on each `perform`. The confirmed automatic
  same-comment retry is DropTriggerJob, not three assumed root producers.
- The topic tool's same-topic/principal condition raises from
  `reject_unrunnable_self_dispatch!`; it is a rejection condition, not permission
  to post. Other authorized topics are allowed and still inherit correlation, so
  the review's cross-topic concern remains valid.

Review source files checked in worktree20945 (runtime unchanged):
`comment.rb`, `drop_trigger_job.rb`, `creatives/trigger_action_command.rb`,
`cron_action_job.rb`, `system_events/dispatcher.rb`,
`orchestration/agent_orchestrator.rb`, `ai_agent/a2a_dispatcher.rb`,
`tools/topic_message_create_service.rb`, `ai_agent_service.rb`, `ai_agent_job.rb`,
`api/v1/agents_controller.rb`, `comment/notifiable.rb`,
`comment_notification_delivery.rb`, `comment_push_delivery_sweep_job.rb`,
`push_notification_job.rb`, and `db/schema.rb`.

Product decisions still pending are completion-based emission, owner handoff,
login/review terminal outcomes, fixed depth/task/step/retry limits, the scope-local
chain boundary, the stated producer deduplication limits, and workflow-only push
preference semantics. No pending decision is inferred from a report posted using
a human-account CLI token. Task 21052 remains incomplete until this concrete
contract is settled; runtime implementation, PR and preview remain unstarted.
