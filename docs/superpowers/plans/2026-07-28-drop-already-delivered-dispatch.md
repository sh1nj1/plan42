# Drop a dispatch whose comment an in-flight turn already delivered

## Problem

Event A and event B arrive as a burst. The agent starts a turn for A. B's
dispatch finds the topic slot taken, parks a waiter, and posts a "⏳" notice.
When A's turn ends the waiter is promoted and the agent speaks a second time.

For a **non-session** agent that second turn is usually redundant:
`MessageBuilder#append_chat_history` reads the topic's comments **at job
execution time**, so if B was committed before A's turn assembled its payload,
B's text is already inside A's context. The agent has read it. Queueing B costs
a waiting notice, a promotion round-trip and a redundant reply.

For a **session-backed** agent it is not redundant at all:
`SessionContextResolver#incremental_payload` keeps only the `:trigger` message,
so A's turn never carried B's text. Dropping B there is message loss, not
de-duplication. #1456's coalescing (merge into `merged_comment_ids`) stays the
correct answer for that case.

So "the agent is busy" is the wrong predicate. The right one is **"this turn
already delivered that comment"** — and whether it did is a property of the
resolved payload, not of the agent's status.

## Approach

Record what was delivered; read the record at the dispatch doors.

### 1. Measure delivery from the payload that is actually sent

`MessageBuilder` tags each `:chat_history` message with the comment id it came
from. `AiAgentService` then reads the ids off the **resolved** payload
(`SessionContextResolver#resolve`), after session filtering, immediately before
streaming starts.

Session-awareness falls out of this rather than being a second switch: a
session agent's resolved payload contains no `:chat_history` messages at all, so
the recorded set is empty and nothing is ever dropped for it.

### 2. Record only what the turn was not created for

The recorded set is restricted to ids **greater than the turn's anchor id**.

Chat history normally holds comments older than the anchor — the ordinary
backlog of the topic. A history comment *newer* than the anchor can only be one
that landed after this turn was dispatched: exactly the burst case. Restricting
to that keeps an old backlog comment from silencing a waiter that was parked for
it long ago.

Ids, not `created_at`: a burst is written by several processes and the clock is
whichever one wrote the row (same reason `MergedTriggerComments` orders by id).

Stored on the task payload under `TaskCoalescer::HISTORY_DELIVERED_KEY`
(`"history_delivered_comment_ids"`), alongside `merged_comment_ids` and
`acquired_comment_id`. Nothing is written until the payload resolves, so a turn
that is running but has not assembled yet drops nothing — fail open.

### 3. Read it at every door

Three doors lead into the queue, and the record has to be read at all of them
(#1456's repeated defect was closing one of two):

| Door | Change |
|---|---|
| `AgentOrchestrator#enqueue_jobs` | new drop gate before `perform_later`/`park_waiter` |
| `AiAgentJob#admit_or_defer!` (late admission) | same gate |
| `AgentOrchestrator.refresh_deferred_context!` (promotion) | free — `delivered_comment_ids` gains the new key, so an already-parked waiter whose anchor was swallowed is filtered out and cancelled by the existing path |

The gate is `Task.delivered_in_flight_for_comment?(agent_id, comment_id, topic_id:, creative_id:, trigger_event_name:)`, scoped exactly like
`delivered_comment_ids` (same agent, topic, creative, trigger event) and
restricted to `DELIVERED_STATUSES`.

`duplicate_running_for_comment?` stays as-is. It answers a different question
(the same comment anchoring two in-flight turns, unscoped by topic) and folding
the two would widen either its scope or the new one's.

### 3a. The promotion floor this opens up

Filtering a waiter's own anchor out of the refresh's candidate scope has a
consequence the existing code never had to handle: the refresh picks the newest
*remaining* eligible comment, and with the anchor gone that is an **older** one.
The waiter would answer a comment it was not dispatched for, that predates the
one it was, and that the covering turn already had in view.

So when — and only when — `delivered_ids` contains the waiter's own anchor, the
candidate scope also gets a floor at that anchor id. Nothing left at or above it
means the waiter has nothing to say, and the existing `unless latest_comment`
branch cancels it.

Deliberately not a blanket "the refresh never moves backwards": an anchor that
left the turn for some other reason (moved to another creative, made private) is
a different question, and a wider floor would change promotion for waiters this
feature never touches. `StuckDetector`'s self-heal tests are the live proof —
they promote waiters whose anchors are not the newest comment around.

### 4. Exclusions

- **Review requests are never dropped.** A review is bound to the comment it
  quotes; `ReviewHandler` can only run as its own turn. Being read as history is
  not being answered.
- Private and approval-action comments never enter history
  (`public_only.without_approval_action`), so they are never recorded.

### 5. Policy switch

`scheduling.drop_delivered_dispatches`, default `true`, resolved per agent like
`coalesce_pending_tasks_for?`. Off ⇒ recording still happens (harmless, and it
keeps the promotion filter honest) but the two dispatch doors do not drop.

## Evidence trail

No ghost `cancelled` row is created for a dropped dispatch. The evidence lives
on the covering task: "which turn ate comment N" is a query over
`history_delivered_comment_ids`, the same shape as `merged_comment_ids`. The
drop is logged with the covering task id.

## Tests (each red before its fix)

1. `MessageBuilder#build` tags history messages with `comment_id`.
2. Resolved payload for a session agent contains no `:chat_history` → recorded
   set empty (negative control for the whole feature).
3. `AiAgentService` records ids newer than the anchor; records nothing for ids
   older than the anchor (negative control).
4. `Task.delivered_in_flight_for_comment?` — true/false across statuses, and
   false across a different topic / creative / agent / trigger event.
5. `AgentOrchestrator.dispatch` creates **no task and no waiting notice** when
   covered; negative control: not covered ⇒ waiter + notice as today.
6. `AiAgentJob` late door drops the same case.
7. A waiter parked *before* the covering turn assembled is cancelled at
   promotion and its waiting notice removed.
8. A review comment is never dropped.
9. Policy off ⇒ no drop.
