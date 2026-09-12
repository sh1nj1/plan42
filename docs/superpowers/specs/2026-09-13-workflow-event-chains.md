# PR4: workflow events and chained execution

Status: implementation proposal. The emission timing question has been sent to
the product owner; the recommended completion-based semantics below are new PR4
decisions, not approvals inherited from PR3. This document is reviewable before
runtime changes are made.

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
provider handoff failure. `done` alone is insufficient. `running`, `delegated`,
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
are executable. Keep unknown `emits` as a save-time advisory for PR3 compatibility;
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
  A repeated ID in a different scope is refused, not treated as authority.
- Unique execution identity is `(chain_id, input_event_id)`. Persist the winning
  rule snapshot, selected responders, admission outcome, input envelope and
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

Root identity must also survive producer retries. The current comment callback
creates a new UUID on each dispatch, so uniqueness on envelope ID alone does not
deduplicate a repeated callback. For workflow admission, persist a root receipt
keyed by `comment_callback/comment_created/comment_id`, with its envelope, before
effects. Other producers must supply a stable delivery key for their invocation
(for example persisted trigger run or cron occurrence), or preserve a persisted
envelope. A deliberate user restart receives a new invocation key. Do not infer
that two different sources or two deliberate restarts of one comment are retries.
Off/shadow retain their existing producer behavior and do not create receipts.
Producer calls without stable identity have only envelope-ID deduplication;
the implementation must expose that limitation rather than claim universal
exactly-once root delivery.

Queue acceptance is not handler completion. PostgreSQL row locks and unique
indexes are the concurrency authority; SQLite tests also exercise database
constraints. `Rails.cache`, process-local sets, or scans over task JSON alone are
not sufficient for deduplication or budget accounting.

## Bounds and termination

Proposed fixed PR4 defaults (new decisions, not previously approved):

- Maximum child envelope depth: **8** (root depth 0; depth 8 may run but cannot
  create depth 9).
- Maximum admitted agent tasks per correlation: **16**, shared across fan-out and
  all steps. Reserve the entire selected/admitted set atomically before enqueue;
  if it does not fit, stop the step instead of truncating responders.
- Maximum workflow executions per chain: **16**, counting agent, human and none
  decisions. Repeated deliveries and blocked duplicates consume no additional
  budget. Existing upstream envelope depth counts; PR4 does not reset it.
- The same rule creative ID may execute only once per chain. Encountering it
  again records `cycle`, including A -> B -> A and self-emission. New root events
  may legitimately run the same rule again.
- Invalid negative/malformed depth, inconsistent correlation/scope, unknown event,
  missing anchor, or deleted/private/moved anchor stop without fallback.

Once a correlation is workflow-managed, every descendant agent admission goes
through its budget gate, including A2A mentions, primary-agent routing and
expression fallback. Those retain their existing routing precedence but do not
run a workflow rule's emits. Record their event admission without a rule ID.
A2aDispatcher must preserve the managed-chain identity and a stable delivery key
based on parent execution and reply comment. Its direct handoff and a configured
emits are distinct edges; both consume the same task/depth budget. Merely clearing
mentions in the emits payload cannot constrain the separate A2A dispatch already
performed by response finalization. Re-entering a workflow rule via either edge
uses the same cycle guard. Unmanaged ordinary A2A dispatches remain unchanged.

Record terminal reason codes: `completed`, `human_handoff`, `ignored`,
`no_eligible_agent`, `scheduler_rejected`, `task_failed`, `empty_reply`,
`permission_revoked`, `scope_changed`, `routing_disabled`, `unknown_emit`,
`depth_exceeded`, `task_budget_exhausted`, `step_budget_exhausted`, `cycle`,
`delivery_failed`. Logs carry IDs, event name, correlation, depth and reason;
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

PR4 chooses one explicit responsibility rule: the effective target creative's
human owner (not the workflow configuration owner, rule creator, commenter,
mentioned people, all shared users or an arbitrary `agent_ids` value). Recheck
current feedback permission using authoritative permission resolution, and require
that the anchor is public and still in the same creative/topic. If the owner is
absent, an AI user, revoked or otherwise ineligible, record a blocked handoff;
never substitute a recipient or agent.

Persist a localized action-needed notice in that person's Inbox System topic,
linked to the source conversation. Dedup key is execution ID plus recipient ID.
Do not include private rule titles or rule content: a target owner may lack read
access to the pinned workflow. The notice is a system-authored comment with
`skip_dispatch`, and must not recursively trigger workflow or regular inbox
notifications. Respect push preferences using the existing push path. Presence
must not suppress the durable action-needed inbox entry.

`PushNotificationJob` currently does not enforce `notifications_enabled` itself.
The workflow notification adapter must check it explicitly; do not assume that
calling the existing job supplies this preference gate.

Use the existing Comment notification unique key and delivery table where
possible. One inbox entry is guaranteed per execution/recipient. External push
is best effort and can be delivered more than once if the process dies after
provider acceptance but before acknowledgement; do not advertise exactly-once
push. Recheck permissions before enqueuing a pending push. PR4 has no human
completion button; replying to the source topic is a separate external event.

## Integration map discovered in current code

- `WorkflowRouting#match_by_workflow` currently discards the matched Rule. Expose
  its decision through Matcher/Selection without side effects, in `on` only.
- `AgentOrchestrator#dispatch` returns early for an empty selected set. Handle
  matched human/none before that return; keep ordinary dispatch unchanged.
- `SystemEvents::Dispatcher` reuses a same-name envelope. Feed it the persisted
  child without `parent:` on retries, or it would generate a fresh child.
- `AiAgentJob#admit_or_defer!` and `AgentOrchestrator#park_waiter` are the two task
  insert doors. Both must enforce the execution/agent unique identity.
- `Task#after_update_commit` covers normal completion. `TaskClaimService#finalize`
  uses `update_all` and then `fire_completion_callbacks_after_external_claim`;
  this supported escape hatch must run the same workflow settlement hook.
- A recurring settlement/outbox sweep is mandatory because callbacks and queue
  acceptance are not atomic. Scope it to unfinished workflow records.
- `Comment::Notifiable` already has transactional unique inbox insertion and a
  push delivery record, but its recipient policy and private helper cannot be
  called unmodified for human workflow responsibility.

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
| Duplicate delivery/completion; two concurrent workers | One execution, one task per agent, one child and one budget reservation |
| Crash after completion commit or before enqueue | Sweep recovers persisted outbox without new envelope IDs |
| Queue rejects or partially accepts jobs | Bounded retries, no duplicate durable admissions or Arbiter rotation |
| Task budget 15 with two responders | Whole step stops; no partial response truncation |
| Root depth 0 / child depth 8 / request for depth 9 | Root accepted; depth 8 accepted; depth 9 blocked |
| A -> A and A -> B -> A | Cycle stops before repeated rule executes |
| Same rule in a new root correlation | Independent execution with fresh budgets |
| Scope/mode/permission/anchor changes while queued | Fail closed with a reason; no new child or notification |
| Owner present, absent, AI, no permission; duplicate delivery | Exactly one eligible human owner inbox entry, otherwise recorded block |
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
