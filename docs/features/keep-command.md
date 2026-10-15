# Keep command

Post `/keep` in a creative's discussion to continue agent work until the goal
is satisfied, user input is needed, or the iteration limit is reached.

```text
/keep [--max 10] [@agent:] [goal]
```

- `goal` is optional. Omit it to follow the creative's existing context and
  trigger instructions.
- `@agent:` optionally selects an AI agent by mention. Without it, normal
  speaking and workflow routing rules choose who responds.
- `--max` accepts an integer from 1 to 50 and defaults to `10` iterations.
  It is parsed only before the agent or goal; later occurrences remain goal text.
- The author needs write permission on the creative. Private `/keep` comments
  are rejected; loop instructions and continuation comments are public.

For example:

```text
/keep --max 5 Fix the failing login tests
/keep --max 10 @Astra: Prepare the release
/keep
```

Use the last form when the existing context already describes the work.
The loop stays in the command's topic, defaulting to Main when none is selected.

## Shared drop-trigger lifecycle

`/keep` starts a loop directly. A drop trigger starts one when a creative enters
an enabled container. Both use the same iteration checks, completion verification,
status display, and Pause, Resume, and Restart controls.

Agents report `[STATUS: CONTINUE]`, `[STATUS: DONE]`, or `[STATUS: BLOCKED]`.
Completion enters `pending_verification` before `completed`; blocked work enters
`awaiting_user`. The loop can also become `paused`, `max_reached`, or `stuck`.
Responses without a status tag use the existing LLM evaluation fallback. If no authorized parent-shared evaluator is available, the keep task agent is also eligible, including agents shared only on the child. Every candidate must retain current read access to the child.
Infrastructure retries do not consume iterations and stop as `stuck` after
three consecutive infrastructure failures.

Reply publicly in the loop's topic to continue work waiting for user input.
Private replies are saved without resuming the loop. Public keep replies skip ordinary
dispatch; only the synthetic resume turn is dispatched, using normal routing
when no agent was selected. An explicitly selected agent remains the only target,
even if the reply mentions another agent.
Resume keeps
the iteration count; Restart resets it and reuses the saved goal and agent
selection. An omitted agent continues to use normal routing after either action.

Each creative stores one loop in `data.trigger.loop`, shared across topics.
Starting another `/keep` replaces an inactive loop, including a previous
drop-trigger loop. Keep loops do not require a drop-enabled parent container.
Linked creative views show and control the effective origin's keep loop; controls require write
permission on that origin.

Agent selection uses only a leading `@name:` token after `/keep` or its `--max`
option. Mentions inside the goal remain part of the goal. A leading selector
that cannot resolve to an eligible AI agent is rejected instead of falling back
to normal routing.

An active loop (`running` or `pending_verification`) must be paused before
starting another `/keep`. Restart continues the stored loop source, goal, topic,
and routing; restarting a completed keep loop under a drop container restarts
that keep loop. A fresh drop trigger replaces any keep loop except one that is
`running` or `pending_verification`, including paused or user-blocked keep loops.
Keep loops under drop containers inherit the container context for verification
and status evaluation. Evaluators require current read access to the loop creative
before receiving its goal, description, or agent response, even when selected
through a parent container or a stale permission cache.

Replacement drop loops create a fresh trigger comment and scope retries to that
generation. Pausing invalidates evaluations already in flight, including when
the loop is resumed before an evaluator returns.

Explicit agent selection is revalidated against current feedback permission
before each continuation or infrastructure retry. If the selected agent is
missing or no longer authorized, the loop enters `awaiting_user` without
rerouting. Human replies in that loop topic are saved without dispatching to
another agent while the selection is unavailable. Resume and Restart reject an
unavailable selection until access is restored or a new `/keep` selects a
different agent.

Keep loops track the current trigger comment. Unrelated topic tasks and duplicate
completions cannot advance that turn. An abandoned inline-login replay yields only to
a newer task serving that same turn; unrelated discussion work cannot block
its transition to `awaiting_user`. If initial or continuation routing schedules
no agent (including an Inbox-ineligible session agent), the loop enters
`awaiting_user` and posts a notice instead of remaining running without a task.
If initial dispatch raises, the current running keep turn also returns to
`awaiting_user`, allowing Resume or a new `/keep`. The original dispatch error
is still reported; a concurrent Pause or replacement turn is preserved.

An explicit keep agent is the only routing target even when the goal mentions
other agents; the displayed goal text is preserved. An active keep loop also
suppresses drop dispatch until its shared slot becomes inactive. Evaluators
revalidate the generation, control version, state, and current turn under the
lock used to create and dispatch continuations, so a completed Pause prevents
stale evaluators from posting further work.

Deleting the topic used by a keep loop clears that loop configuration, allowing
a new `/keep` in another topic. Other trigger settings and loops referencing
other topics are preserved. No-agent notices are posted after the creative
state-update lock is released.

Status evaluation and completion verification use the accepted task's linked
reply. Later responses from the same agent in the topic cannot replace that
result; a missing linked reply does not fall back to unrelated comments.

Keep commands detach quoted-comment and review metadata before saving. They
start ordinary loop turns rather than reviewing or replacing the quoted reply.
Human-reply resumes revalidate the saved loop snapshot under topic and creative
locks before creating and dispatching their continuation, so Pause or a newer
control version invalidates a resume already in flight.

Deleting the current keep turn comment clears its loop configuration in the
same transaction, including queued or running turns. Deleting an older turn
or an unrelated comment leaves the current loop intact. Other trigger settings
and drop loops are preserved.

### Interrupted turns

Stopping, failing, or escalating the last task serving the current keep turn
changes a running loop to `awaiting_user`. Completing without a finalized reply
(including a blank response whose placeholder is removed) also releases the turn
without consuming an iteration. Login waits still delegate to their replay.
A coalesced replacement or another
active/completed task serving that same turn retains ownership. Resume or a new `/keep` can then start work again. Unrelated
tasks, paused loops, and drop loops are unaffected.

A dropped current dispatch retains ownership while restoration is pending. If
permission or scheduler admission refuses restoration, that refusal is recorded,
the dispatch is excluded from subsequent sweeps, and the last owner releases the
keep loop to `awaiting_user`. Admitted restoration retains ownership until its
replacement task starts. Pending restoration owned by another task serving the
same turn also retains ownership; unrelated pending comments do not. Dropped keep
turns retain their original dispatch generation, including jobs dropped after a
replacement starts. Restoration revalidates that generation and the running
current turn under the creative lock; paused or superseded work is not enqueued.
A rejected restoration enqueue releases its claim and returns the current keep
to `awaiting_user`. Ordinary dispatch restoration remains retryable.

Initial keep dispatch requires queue acknowledgement. A rejected enqueue leaves
the committed command in `awaiting_user` rather than claiming an agent is working.
If enqueueing the completed turn's status check raises or returns false, that
exact running turn also returns to `awaiting_user` without consuming an iteration.
A concurrent Pause, replacement loop, or newer turn is preserved.

If enqueueing completion verification raises or returns false, the accepted
running turn and its counters are restored so the status check can retry.
Recovery preserves a concurrent Pause or replacement loop.

If continuation, infrastructure-retry, or failed-verification dispatch raises
or its enqueue is rejected,
the new comment and tasks roll back and the accepted evaluator turn is restored,
including its previous iteration and retry counters. The evaluator can retry
that turn; recovery never overwrites a newer Pause or replacement loop.

Status evaluators and completion verifiers include a configured context creative
only when the selected verifier currently has read permission. These checks use
authoritative shares, so revocation and explicit denial take effect even before
the asynchronous permission cache refreshes. Readable contexts remain deduplicated.

UI Resume and Restart commit their state transition together with continuation
creation and dispatch. A creation or dispatch error rolls back the prior state,
iteration counters, and control version, so the same action can be retried.
Public reply resumes likewise return to their previous awaiting-user state on
failure, including rejected enqueues; the human reply remains saved and another
reply can retry the resume.
Controls whose loop topic or start comment changed before locking do not affect
the replacement, including a new keep loop in the same topic.

Completion verification filters candidates by current read access to the loop
creative before preferring a different agent. If every alternative is denied,
an authorized task agent can still verify the result, including an explicitly
selected agent shared only on the child rather than the drop container.

Keep dispatches revalidate their recorded generation, current turn, running state,
and current agent access when the queued job starts, including delayed restores
and promoted waiters. Paused or superseded jobs do not start agent work. An
execution-time refusal returns the unchanged turn to `awaiting_user` when no
other task, pending restoration, or acknowledged queued job owns it. Each
accepted keep job records its agent on the current turn until it reaches
admission, so one sibling's refusal cannot release a turn while another routed
agent's job is still queued. A refused restored job clears its
restore claim and records refusal before deciding whether ownership remains.
Admission uses the controls' topic-to-creative lock order; provider execution
runs after those admission locks have been released.
Same-anchor payload rebuilding (including inline-login replay) retains that
original identity; acquiring a different anchor uses the new comment's identity.
