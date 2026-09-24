# Human approval gates

Native Collavre agents can call `approval_request` to ask a person for a decision
and suspend the current task. Enable it in the agent's tools, or discover and run
it through `meta_tool`:

```json
{
  "action": "run",
  "tool_name": "approval_request",
  "arguments": {
    "question": "Publish the reviewed release notes?",
    "approver_user_id": 123
  }
}
```

`question` is required and supports Markdown. `approver_user_id` is optional and
defaults to the triggering comment's author. The approver must be a human with
read access to the creative. If the trigger has no human author, specify an
eligible person explicitly. The agent may select any human with read access;
write or feedback access is not required. This gate records advice to the agent
and does not grant additional permissions to execute the proposed action.
Invalid questions or approvers return a tool error so the agent can correct them.

The designated person sees the existing approve/deny buttons and an optional
reason field. Administrators who are not the designated approver cannot decide
the gate and do not see these controls. Either response resumes the original call with:

```json
{"decision":"denied","reason":"Revise the release date first","decided_by":123}
```

A denial is a normal tool result: reconsider the plan and do not perform the
denied action. No response leaves the task pending indefinitely. Automatic
expiration, automatic denial, multiple-choice options, and automatic slot
reclamation are not part of this feature. Existing task cancellation remains
available; a cancelled or superseded request cannot resume work. Pending approvals
remain in the agent concurrency count even after the resource cache expires;
waiting does not free capacity for another topic.

## Execution and recovery

The native `AiClient` intercepts direct calls and `meta_tool run` calls before
execution. `ApprovalGateHandler` atomically records a provider-neutral conversation
snapshot, original tool-call ID, pending task state, and approval comment. Images,
completed tool results, and provider thinking signatures survive resumption.

The response is injected as a result for that exact call, without asking the model
to repeat it or executing a tool server-side. Other unfinished calls in the same
batch receive an explicit not-executed result so the model can reconsider them.
New comments posted during the pause are not recorded as read by this snapshot.

Decision recording locks both task and comment. Duplicate clicks cannot schedule
multiple decisions. The resume job is enqueued only after the decision transaction
commits, including any outer transaction. The resume job uses the existing agent
lifecycle with an atomic pending-to-running admission check; duplicate delivery cannot start a
second worker. Before admission, an interrupted resume can be retried. The gate
payload, including embedded image data, is retained while work is active and
cleared atomically when the task finishes, fails, is cancelled, or is escalated.

The gate comment is the only surface that can decide its task. Deleting it, or
moving it to another topic or creative, cancels a still-undecided gate task and
releases its agent reservation and topic slot. An already-decided gate keeps
resuming normally.

The native `approval_request` tool supports native Collavre LLM turns, including
their dynamic meta-tool calls. Plain external MCP sessions have no conversation to
restore and cannot suspend on it; the tool returns an explicit error there.

## Claude Channel sessions

A Claude Code session's conversation lives inside the Claude Code process, so
Collavre cannot snapshot and resume it. What it *can* block is the tool call
itself, which is exactly what the native tool-permission relay already does — so
a Claude Channel session asks through its own plugin tool, `approval_request`,
which rides that same rail:

1. The plugin posts the question to `POST /api/v1/agent/notify` with
   `approval_question` plus a `permission_request_id`, and holds the MCP tool call
   open.
2. The server builds an approval comment whose body is the question verbatim,
   with the approver gate and the same approve/deny buttons plus reason field, and
   parks the in-flight delegated task (`pending_tool_call`) so the decision reaches
   the blocked session instead of queuing behind the topic's concurrency slot.
3. The decision is broadcast over the agent stream with the reason and who
   decided. The plugin resolves the waiting tool call, so the model sees an
   ordinary tool result — `approved`/`denied` with `reason` and `decided_by` — and
   loses no context. A decision clicked while the WebSocket was down is
   redelivered by the same pull-on-resubscribe replay as a tool prompt.

Differences from the native gate:

- The approver defaults to the token holder running the session (a native gate
  defaults to the triggering comment's author). `approver_user_id` overrides it
  and is validated the same way: a human with read access to the creative.
- One locally tracked request at a time. A second question while one is
  open is refused and names the open `request_id` instead. Requests handed to
  the server at reply no longer block a later turn from asking another question.
- A single tool call does not wait forever: it stays open for
  60s by default, or 80% of the Claude Code process's existing
  `MCP_TOOL_TIMEOUT` (clamped to 1ms–1h) when that is set. It then returns
  `pending` with the `request_id`. The human has no
  deadline — the model either calls again with that `request_id` to keep waiting,
  or ends its turn saying it is blocked. A decision made in between is cached and
  delivered by the next call.
- The wait budget includes the HTTP relay. A network failure or server error
  leaves delivery uncertain, so the plugin retains the request ID for replay
  and re-await instead of creating a duplicate question. Explicit validation or
  authentication rejections release the ID because no question was saved.
- If an undecided gate is deleted, the plugin receives no deletion event.
  After confirming deletion, call `approval_request` with the same `request_id`
  and `abandon: true` to release the local wait and reconnect replay tracking.
  This permits a new question without restarting the session. It does not
  approve an action, decide or delete any server comment, or hand off a
  continuation. Do not use it merely because a person has not answered yet.
- Ending with `reply` hands unread requests to the server atomically with the
  reply. This includes decisions cached after a pending result but not yet read
  by the model. Decisions already returned by the tool are excluded.
- After both the reply and decision are committed, Collavre posts a decision
  message and queues one new task for the requesting agent in the same topic.
  It includes the question, decision, reason, and decider. The completed task
  stays completed; this is a new channel turn, not a restored tool call.
- The approval comment stores the original and continuation task IDs. Duplicate
  jobs and reconnect recovery reuse that task. Decisions arriving just before,
  during, or after reply therefore take the same path. Reconnecting also recovers
  an interrupted enqueue; existing offline-task recovery handles an offline
  continuation. No local request tracking needs to survive the completed turn.
- Continuations use the ordinary topic queue and retain their decision message
  rather than coalescing with unrelated chat. A cancelled origin, removed topic,
  or lost agent feedback access does not create a continuation. Server and plugin
  must both be upgraded: the reply payload carries `pending_approval_ids`.
  Native tool-permission prompts retain their existing end-of-turn cleanup.

Delegated OpenClaw processes and plain external MCP sessions without an active
Collavre task are not covered by this integration. Existing Claude Channel permission
prompts and automatic tool approvals retain their separate behavior.

## Codex CLI approval through MCP

Codex CLI (`cli_proxy`) turns use the same `approval_request` tool discovered
through `meta_tool`. Collavre supplies the current `task_id` in each trigger,
including incremental session prompts. Send that ID with the question:

```json
{"action":"run","tool_name":"approval_request","arguments":{"task_id":123,"question":"Publish the reviewed release?"}}
```

The MCP caller must be the task's agent or its creator, and both caller and agent
must have feedback access to the creative. The task must be running and belong
to an existing topic. The default approver is the task's effective human
workspace principal; an explicitly absent principal requires an explicit
`approver_user_id`. Every approver must be human and have read access.

The tool persists a gate and immediately returns `status: pending`, `request_id`,
and an instruction to end the turn. The agent must not perform the proposed
action while pending. It ends normally; no worker or topic slot is held waiting
for the person. One gate per task is reused on retries, including a decision
that arrives before the original turn finishes.

After both a human decision and successful turn completion, Collavre posts the
question, decision, reason, and decider in the same topic and queues a new turn
for only the requesting agent. This reconstructs context from Collavre messages;
it does not restore a provider tool-call stack. Decisions arriving before or
after completion follow the same path. The stored continuation task ID prevents
duplicate tasks, and approval continuations cannot be coalesced with unrelated
chat or reassigned by a topic's primary-agent setting. The original workspace
principal is preserved, including explicit absence. A recurring sweep runs every
minute in production, development, and desktop environments to recover committed
decisions whose resume enqueue was interrupted. It also retries dispatch of an
already-created queued or pending continuation; the persisted task ID prevents
another continuation from being created. One failed recovery does not block other
gates, and the next sweep retries it.

Deleting or moving a gate withdraws it without cancelling the running Codex turn.
A deleted gate needs no local cleanup because Codex retains no waiting tool call.
Cancelled/failed origins, private or moved gates, missing topics, and revoked
agent feedback access do not start a continuation. Denial is delivered as a
normal decision and does not authorize the proposed action.

This requires the server version containing Codex support. Claude Channel still
uses its plugin tool; native Collavre turns keep their original pause/resume path.
