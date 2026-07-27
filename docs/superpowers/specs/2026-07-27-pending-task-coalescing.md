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

`Scheduler#evaluate` counts occupants, but the task row is only created **inside**
`AiAgentJob`. Dispatches that arrive before the first job runs all see zero
running tasks and are all judged `:immediate`, so several tasks run concurrently
in one topic despite `topic_max_concurrent_jobs = 1`.

### Constraint: cancelling is not enough

For session-backed agents (`supports_session?` — Claude Channel / CLI adapters)
`SessionContextResolver#incremental_payload` sends **only** the `:trigger`
message and drops chat history. Cancelling the older tasks and running just the
newest would therefore silently drop the content of every intermediate comment.
The older comments must be **merged into** the survivor, not discarded.

## Solution

Keep exactly one un-started task per `(agent, topic, creative, trigger_event)`
and fold the superseded triggers into it.

### `Orchestration::TopicSlot`

One rule for who may hold a topic's concurrency slot, shared by every path that
hands one out. Two entry points:

- `TopicSlot.lock!(topic_id, creative_id)` — `SELECT ... FOR UPDATE` on one
  stable row, so admission, promotion, folding and notice posting for one topic
  scope all serialize against each other. `topic_id: nil` is a real scope (a
  creative's Main topic) with no topic row, and tasks carry `topic_id` with no
  foreign key, so a missing topic falls back to the **creative** row. Returning
  `nil` there would run those paths with no serialization at all — silently the
  one state the lock exists to prevent. The SQLite visitor drops the lock clause;
  serialization is a Postgres property.
- `TopicSlot.available_for?(agent_id, topic_id, creative_id, context)` —
  occupancy counts `running`/`delegated` **plus** `pending` (claimed, job not
  started) and `pending_approval` (paused, still holding the resource). A free
  slot is not automatically *this* agent's to take: `topic_max > 1` exists to run
  *different* agents in parallel, so an agent already in flight here waits.

Deliberately **not** gated on `coalesce_pending_tasks?`. That switch governs
whether waiters are folded, not whether `topic_max_concurrent_jobs` is enforced.

### `Orchestration::TaskCoalescer`

`TaskCoalescer.coalesce!(keep_task, scope: :older | :all)`:

- Selects sibling tasks with the same `agent_id`, `topic_id`, `creative_id`,
  `trigger_event_name` and `status: "queued"`.
- `scope: :older` (the enqueue doors) adds `id < keep.id`, which guarantees a
  survivor when two dispatches coalesce concurrently: each only ever cancels
  strictly older rows. `scope: :all` (the promotion and start-of-turn doors)
  drops the guard, because the survivor has already left `queued` — nothing can
  cancel it, and the waiters left behind are *newer*.
- Locks the survivor **together with** its siblings in one id-ordered statement,
  then re-reads the survivor's status from the locked row and aborts unless it is
  still in `UNSTARTED_STATUSES` (`queued`/`pending`). `Comment#cancel_pending_tasks`
  can cancel the survivor from a deletion transaction that holds no lock this
  method waits on; folding on that stale object would cancel every still-valid
  sibling onto a task `AiAgentJob` abandons on sight. One id-ordered statement
  rather than `keep.lock!` first: in the `:older` scope the survivor's id is
  above every sibling's, so taking it first would descend where a concurrent
  fold ascends — the shape a deadlock needs.
- Sibling statuses are re-checked against the locked rows too; the id list came
  from an unlocked read.
- Each absorbed task is cancelled (`update!`, so audit callbacks still run) and
  recorded as a `TaskAction(action_type: "superseded")`.
- The absorbed comment ids — plus anything those tasks had already absorbed —
  are merged into `keep.trigger_event_payload["merged_comment_ids"]`, sorted,
  with the surviving anchor id removed. The merge reads its base payload from
  the locked row but **writes through the caller's object**, because
  `dequeue_next_for_topic` hands that same instance to `refresh_deferred_context!`
  on the next line.

The **newest** task survives, so the payload's `comment` stays the newest
comment: reply anchoring, `quoted_comment` review handling, and image
attachment all keep pointing at the message the user actually sent last.
Ordering is by `id` alone rather than `created_at` — `created_at` is
caller-settable, so a retraction could otherwise sort ahead of what it retracts.

Coalescing is scoped **per agent**, so `topic_max_concurrent_jobs > 1` keeps
doing what it is for: several *different* agents still run in parallel in one
topic. Two waiters for the *same* agent in the same topic are one conversation
turn no matter how many slots exist, so they are folded regardless of
`topic_max`.

**Review requests neither absorb nor get absorbed.** A review is an action bound
to one comment, not one more message in the burst: `AiAgentService` and
`ResponseFinalizer` read review behaviour off the surviving anchor alone, so
folding across that boundary degrades an absorbed review into a normal reply and
lets a surviving review overwrite its quoted comment with text answering an
unrelated message. `refresh_deferred_context!` leaves a review anchor where it
is for the same reason — but not moving it is not the same as not checking it.
An ordinary anchor is revalidated by having to be re-selected through the
eligibility scope, so the review branch asks the same question directly
(`MergedTriggerComments.in_turn`) and cancels the turn when the answer is no.
The anchor is the one part of the payload rendered without a filter and
`ReviewHandler#eligible?` only inspects the *quoted* comment's privacy, so a
review request withdrawn while it waited would otherwise still be delivered from
cache and still drive an in-place revision.

### Call sites

1. `AgentOrchestrator#park_waiter` — the `:deferred` enqueue door. Creates the
   waiter and folds its predecessors **in one transaction under `TopicSlot.lock!`**,
   the same lock the other enqueue door already takes. Serialized creation is
   what makes `id < keep.id` read as "everything already parked".
2. `AiAgentJob#admit_or_defer!` — the late-admission door. `TopicSlot.lock!`,
   `TopicSlot.available_for?`, and `Task.create!` (as `running` or `queued`) are
   one transaction, so the decision and the insert cannot be separated.
3. `AgentOrchestrator.coalesce_promoted!` — after a waiter is promoted
   (`scope: :all`).
4. `AgentOrchestrator.coalesce_at_start!` — under the topic lock immediately
   before execution (`scope: :all`), for waiters parked between the claim and the
   start of the turn.

### Re-anchoring

`refresh_deferred_context!` is merge-aware: when the refreshed anchor is a
*different* comment than the payload's current one, the previous anchor is pushed
into `merged_comment_ids` instead of being dropped, and the payload's `"sender"`
block is rebuilt with it (`ContextBuilder` fills that with `||=` and never re-runs
on this path).

Both doors that move an anchor — this one and `Comment#reanchor_coalesced_task` —
write it through `TaskCoalescer.reanchor_payload`, which also records the move
under `acquired_comment_id`. A payload therefore *says* whether its anchor is the
comment the task was created for, rather than leaving a later reader to infer it
from timestamps (see `delivered_comment_ids` below). The mark is written only when
the id actually changes, and never cleared.

Two restrictions on the destination:

- `absorbed_only:` — `coalesce_at_start!` (the call site this branch added)
  restricts the destination to the task's own anchor plus what coalescing folded
  into it. The topic lock orders *task creation*, not comment visibility, so a
  comment committed before its `AiAgentJob` materializes a task would otherwise
  be adopted here and answered again by its own waiter later. The promotion path
  keeps its topic-wide destination, which predates this branch and is its stated
  purpose.
- `delivered_comment_ids` — a comment another turn of the same agent has already
  delivered is excluded from both the destination and the merged list. A comment
  counts as delivered by another turn only if it is in that turn's merged list,
  or is that turn's anchor *and* recorded as acquired (`acquired_comment_id`);
  an anchor the turn was created for is its own trigger, and counting it would
  cancel every waiter standing behind an answered comment. The distinction comes
  from the payload rather than from `comment.created_at` against
  `task.created_at` — those are stamped by whichever process wrote each row, so a
  tie or a skew reads an acquired anchor as an original one (answering it twice)
  or an original one as acquired (cancelling a waiter with no candidate left).
  It is the same reason ordering here is by `id`. Judged at
  promotion rather than at dispatch, so a turn that dies without delivering
  (`failed`/`cancelled`) leaves its comments answerable — rejecting the second
  dispatch instead would turn a duplicate into a loss.

`Comment#reanchor_coalesced_task` runs on anchor deletion, **before** the
cancellation branch: the task moves onto the newest comment it absorbed rather
than being cancelled, and only a task with nothing left to say is still
cancelled. It takes `task.lock!` inside a transaction and re-reads the status
there (a snapshot saying `queued` may have started since, and a started turn has
already been handed its payload). `RecordNotFound` from the lock returns `false`
rather than raising out of an `after_destroy_commit`. Candidates are scoped by
`task.creative_id`/`task.topic_id` — not the deleted comment's, which
`CommentMoveService` may have changed — and go through
`MergedTriggerComments.in_turn`.

### One scoping predicate

`MergedTriggerComments.in_turn(ids, context)` carries
`public_only.without_approval_action` plus the creative/topic scope, and is the
single answer to "is this comment still part of this turn?". Three callers ask
it: the renderer (what is delivered), `Matcher#permits_assignment?` (whether a
merged mention still outranks the topic's primary-agent assignment), and the
re-anchor (what may become the anchor). `merged_comment_ids` is a **snapshot of
the fold**, not a standing claim — `CommentMoveService` can move a comment to
another creative and a user can flip one to private while the burst waits, so a
lookup by id alone would deliver content across a permission boundary. The
anchor slot is the one part of the payload delivered without a filter, which is
why promotion into it must ask the same question.

`context.key?("topic")` rather than a presence check: `topic_id` nil is a real
scope, so "no topic key" and "topic id nil" are different questions.

### Waiting notices

At most one "⏳" topic-concurrency notice per `(creative, topic)` **when
coalescing is on**. Coalescing absorbs the waiters behind it, so N notices would
be N dead ends pointing at one blocker.

- `with_live_topic_wait` (both branches) holds `TopicSlot.lock!` and refuses to
  post a notice once the queue has drained — removal only happens when a
  promotion drains a `queued` waiter, so a notice posted after that cleanup
  describes a wait that is over and nothing will ever take it down.
- `with_deduped_topic_notice` is that plus the existence check, taken only when
  `coalesce_pending_tasks_for?(agent)` is true. Both enqueue doors resolve the
  policy from the dispatch's own context *and its agent*, so a topic where one
  agent coalesces and another does not gets the right answer per dispatch.
- **The kind is recorded, not inferred.** `comments.waiting_notice_scope` is
  `"topic"` for the deduplicated notice and `"task"` for a per-deferral one,
  which also carries `waiting_notice_task_id`. Classifying by "is a sibling
  notice still standing?" holds only while a topic has one kind at a time, and
  the two coexist as soon as the policy differs between agents or changes
  mid-wait: the shared notice then reads as a per-deferral one and takes down the
  newest queued waiter — which is very likely the one the *other* notice speaks
  for. `nil` is a notice posted before this was recorded and keeps the old
  behaviour; widening it would discard work, narrowing it would disarm the only
  stop control an in-flight wait has.
- `topic_concurrency_notice_exists?` counts `"topic"` and legacy notices only. A
  per-deferral notice speaks for one waiter, so letting it answer would leave a
  coalescing agent's waiters with no notice whenever an opted-out agent deferred
  into the topic first.
- Cleanup is `cleanup_waiting_notices_if_drained!`: promotion removes the
  *shared* notice only after confirming under the topic lock that no `queued`
  waiter remains. With `topic_max > 1`, promoting one agent can leave another
  agent's waiter behind, and `coalesce_promoted!` folds same-agent siblings only.
  A per-deferral notice is not subject to that question — `cleanup_waiter_notice!`
  takes down the promoted waiter's own notice unconditionally, or it would keep
  offering a stop button for a turn that is already running.
- `Comment#cancel_queued_tasks_for_waiting_notice` cancels, for a `"topic"`
  notice, every queued waiter in the scope except those a surviving `"task"`
  notice still speaks for; for a `"task"` notice, exactly its own waiter; and for
  a legacy one, the single newest waiter. `queued` only: a `pending`/`running`
  task is the blocker, not a waiter, and is surfaced separately with its own stop
  control.

### Message assembly

`MergedTriggerComments`:

- `prepend_to` / `append_trigger_message` renders the merged comments
  (chronological, `[speaker]: content`) above the anchor's own text, and appends
  their image attachments to the trigger parts.
- `MessageBuilder#merged_comment_ids` excludes only the blocks actually
  rendered, so `append_chat_history` does not send them twice.
- **Size budget.** Coalescing is what makes this bite: a burst that used to
  arrive as N separately budgeted turns is now one indivisible message, so it
  does not degrade — the whole turn fails. `within_budget` keeps **every** block
  and truncates each to `budget / blocks.size` (marked with `…[truncated]`).
  Dropping the oldest blocks was tried and reverted: history caps by
  `chat_history_limit` *count* and by *this same* size budget spread across the
  whole conversation, accumulating oldest-first and breaking — so it cuts from
  the end where a just-dropped burst comment sits — and `append_chat_history`
  builds text parts only, so a dropped block's images reach the agent through no
  path at all. No floor under the per-block share: a budget too small to say much
  per comment is a configuration problem, not one this class should paper over by
  discarding a user's message.

This keeps `SessionContextResolver#incremental_payload` correct without change:
the single `:trigger` message carries every merged comment.

### Policy

`scheduling.coalesce_pending_tasks` (default `true`), reachable as
`PolicyResolver#coalesce_pending_tasks_for?(agent)`, so a creative, topic **or
agent** can opt out. Agent scope is the granularity of the thing being switched —
coalescing folds same-agent siblings — and `#scheduling_config` excludes agent
policies by construction, so the agent-less predicate this replaces could only
ever ignore a User-scoped opt-out. There is deliberately no agent-less variant
left to fall back to.
The opt-out is a real configuration with its own semantics, not "the feature
off": each deferral keeps its own waiter *and* its own notice, and deleting one
notice cancels one waiter. It does **not** disable `topic_max_concurrent_jobs`,
`TopicSlot` serialization, or the drained-queue guard.

## Not doing

Debouncing the *first* message (waiting N seconds before the initial dispatch to
collect a burst) would reduce a 5-comment burst to a single answer instead of
two, but delays every ordinary conversation turn. Out of scope.

Promotion's topic-wide refresh destination has the same duplicate-answer shape
as the `coalesce_at_start!` call site, but it predates this branch (`main`'s
`refresh_deferred_context!` already selects the newest comment in the topic) and
ten tests pin it. Narrowing it means deciding that a waiter should answer only what
it absorbed rather than the current state of the conversation — its own change,
with its own reasoning.

## Test coverage

- `TaskCoalescer`: absorbs older queued siblings; leaves other agents,
  creatives, topics, `trigger_event_name`s, and `pending`/`running` tasks alone;
  never cancels the newest; transitive merge of already-absorbed ids; records
  `TaskAction`; a `cancelled` survivor supersedes nothing (with a `pending`
  survivor as the control); reviews neither absorb nor get absorbed.
- `TopicSlot` / `AiAgentJob`: an occupied topic slot yields a queued waiter, not
  a second running task; an emptied slot re-drains immediately; an agent already
  holding a slot queues even with `topic_max > 1`, while a *different* agent
  still takes the free slot; the opt-out still parks rather than starting a
  second concurrent turn, and still posts one notice per waiter.
- `AgentOrchestrator`: burst of 3 deferred dispatches leaves 1 queued task and
  1 waiting notice; the fold runs with the topic lock already taken and above
  the ambient transaction depth; the notice survives a promotion that leaves
  another agent queued, and is removed once nothing is queued; a promoted waiter
  does not re-answer a comment an earlier turn delivered, and still advances onto
  an unanswered newer one.
- Re-anchoring: an anchor deleted mid-wait re-anchors onto the newest absorbed
  comment in the *task's* creative; a moved, privated, or already-delivered
  comment is not adopted; a stale snapshot cannot overwrite a concurrent fold; a
  waiter with nothing absorbed is still cancelled.
- `Matcher`: a merged mention moved out of the turn no longer licenses it, while
  an in-scope merged mention still does.
- `MergedTriggerComments` / `MessageBuilder`: merged comments appear in the
  trigger in order with their images and are excluded from chat history; an
  under-budget burst renders in full; an over-budget burst keeps every comment,
  truncated, within the budget.
- `PolicyResolver`: default on, overridable off; coalescing disabled restores
  the previous per-comment behaviour.
