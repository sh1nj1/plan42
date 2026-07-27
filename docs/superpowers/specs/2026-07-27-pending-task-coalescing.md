# Coalescing pending agent tasks for burst chat messages

Date: 2026-07-27
Branch: `feat/coalesce-pending-agent-tasks`

## Problem

An external event (a PR comment sync, a webhook burst) can create several
`Collavre::Comment` rows in the same topic within milliseconds. Each one fires
`Comment#dispatch_to_orchestration` → `AgentOrchestrator.dispatch`, so the same
agent ends up with several tasks for one logical conversation turn. The agent
answers N times.

Two independent paths produce the duplication.

### 1. Queued waiters replay the same comment

`topic_max_concurrent_jobs` defaults to `1`, so comments 2..N are `:deferred`
and each creates a `Task(status: "queued")` plus a "⏳" waiting notice.
When the running task finishes, `dequeue_next_for_topic` promotes **one**
waiter, and `refresh_deferred_context!` rewrites its payload to the *latest
non-agent comment*. The agent's own replies are excluded from that lookup, so
every waiter resolves to the **same** last comment and answers it again.
N comments → N-1 identical answers.

### 2. Immediate dispatch races on the topic slot

`Scheduler#evaluate` counts `Task.running_for_topic`, but that row is only
created **inside** `AiAgentJob` (`ai_agent_job.rb:134`). Dispatches that arrive
before the first job runs all see zero running tasks and are all judged
`:immediate`, so several tasks run concurrently in one topic despite
`topic_max_concurrent_jobs = 1`.

### Constraint: cancelling is not enough

For session-backed agents (`supports_session?` — Claude Channel / CLI adapters)
`SessionContextResolver#incremental_payload` sends **only** the `:trigger`
message and drops chat history. Cancelling the older tasks and running just the
newest would therefore silently drop the content of every intermediate comment.
The older comments must be **merged into** the survivor, not discarded.

## Solution

Keep exactly one un-started task per `(agent, topic, creative, trigger_event)`
and fold the superseded triggers into it.

### `Orchestration::TaskCoalescer`

`TaskCoalescer.coalesce!(keep_task)`:

- Selects sibling tasks with the same `agent_id`, `topic_id`, `creative_id`,
  `trigger_event_name`, `status: "queued"`, and `id < keep.id`, locked
  `FOR UPDATE` inside a transaction.
- `id < keep.id` (rather than "everything else") guarantees a survivor when two
  dispatches coalesce concurrently: each only ever cancels strictly older rows.
- `status: "queued"` only. A `pending` task may already be riding an enqueued
  `AiAgentJob`; cancelling it makes that job return early **without** draining
  the topic queue, which stalls the topic.
- Each absorbed task is cancelled (`update!`, so the audit callbacks still run)
  and recorded as a `TaskAction(action_type: "superseded")`.
- The absorbed comment ids — plus anything those tasks had already absorbed —
  are merged into `keep.trigger_event_payload["merged_comment_ids"]`, sorted,
  with the surviving anchor id removed.

The **newest** task survives, so the payload's `comment` stays the newest
comment: reply anchoring, `quoted_comment` review handling, and image
attachment all keep pointing at the message the user actually sent last.

Coalescing is scoped **per agent**, so `topic_max_concurrent_jobs > 1` keeps
doing what it is for: several *different* agents still run in parallel in one
topic. Two waiters for the *same* agent in the same topic are one conversation
turn no matter how many slots exist, so they are folded regardless of
`topic_max`. `StuckDetector`'s multi-slot self-heal is unaffected for distinct
agents and now absorbs same-agent stragglers instead of promoting them into a
duplicate answer.

### Call sites

1. `AgentOrchestrator#enqueue_jobs`, `:deferred` branch — right after the waiter
   is created.
2. `AgentOrchestrator.dequeue_next_for_topic` — after a waiter is promoted, as a
   safety net for waiters created while the promotion was in flight.
3. `AiAgentJob` slot check (below), after a late waiter is created.

`refresh_deferred_context!` becomes merge-aware: when the refreshed anchor is a
*different* comment than the payload's current one, the previous anchor is
pushed into `merged_comment_ids` instead of being dropped.

### Immediate-path slot check

In `AiAgentJob`'s new-task branch, before `Task.create!(status: "running")`:
if the context carries a topic and
`Task.occupying_topic_slot(topic_id, creative_id).count >= topic_max`, create a
`queued` waiter instead of a running task, post the waiting notice, and
coalesce. If no slot holder remains by then (the holder finished in the
meantime), immediately `dequeue_next_for_topic` so the waiter is not orphaned.

`occupying_topic_slot` is the right scope here — unlike `running_for_topic` it
also counts `pending` and `pending_approval`, which do hold the slot.

### Waiting notices

At most one "⏳" topic-concurrency notice per `(creative, topic)`. Coalescing
absorbs the waiters behind it, so N notices would be N dead ends pointing at one
blocker. `post_waiting_notice` skips the create when such a notice already
exists.

### Message assembly

`MessageBuilder`:

- `append_trigger_message` prepends the merged comments (chronological,
  `[speaker]: content`) above the anchor's own text, and appends their image
  attachments to the trigger parts.
- `append_chat_history` skips comments already folded into the trigger, so the
  full-context path does not send them twice.

This keeps `SessionContextResolver#incremental_payload` correct without change:
the single `:trigger` message now carries every merged comment.

### Policy

`scheduling.coalesce_pending_tasks` (default `true`), reachable as
`PolicyResolver#coalesce_pending_tasks?`, so a creative or topic can opt out.

## Not doing

Debouncing the *first* message (waiting N seconds before the initial dispatch to
collect a burst) would reduce a 5-comment burst to a single answer instead of
two, but delays every ordinary conversation turn. Out of scope.

## Test coverage

- `TaskCoalescer`: absorbs older queued siblings; leaves other agents,
  creatives, topics, `trigger_event_name`s, and `pending`/`running` tasks alone;
  never cancels the newest; transitive merge of already-absorbed ids; records
  `TaskAction`.
- `AgentOrchestrator`: burst of 3 deferred dispatches leaves 1 queued task and
  1 waiting notice; promotion does not re-answer an absorbed comment;
  `refresh_deferred_context!` preserves the old anchor when it swaps.
- `AiAgentJob`: an occupied topic slot yields a queued waiter, not a second
  running task; an emptied slot re-drains immediately.
- `MessageBuilder`: merged comments appear in the trigger message in order, with
  their images; they are excluded from chat history.
- `PolicyResolver`: default on, overridable off; coalescing disabled restores
  the previous per-comment behaviour.
