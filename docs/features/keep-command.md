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
Responses without a status tag use the existing LLM evaluation fallback.
Infrastructure retries do not consume iterations and stop as `stuck` after
three consecutive infrastructure failures.

Reply in the loop's topic to continue work waiting for user input. Resume keeps
the iteration count; Restart resets it and reuses the saved goal and agent
selection. An omitted agent continues to use normal routing after either action.

Each creative stores one loop in `data.trigger.loop`, shared across topics.
Starting another `/keep` replaces an inactive loop, including a previous
drop-trigger loop. Keep loops do not require a drop-enabled parent container.

Agent selection uses only a leading `@name:` token after `/keep` or its `--max`
option. Mentions inside the goal remain part of the goal.

An active loop (`running` or `pending_verification`) must be paused before
starting another `/keep`. Restart continues the stored loop source, goal, topic,
and routing; restarting a completed keep loop under a drop container restarts
that keep loop. A fresh drop trigger replaces any keep loop except one that is
`running` or `pending_verification`, including paused or user-blocked keep loops.
Keep loops under drop containers inherit the container context for verification
and status evaluation.

Replacement drop loops create a fresh trigger comment and scope retries to that
generation. Pausing invalidates evaluations already in flight, including when
the loop is resumed before an evaluator returns.

Explicit agent selection is revalidated against current feedback permission
before each continuation or infrastructure retry. If the selected agent is
missing or no longer authorized, the loop enters `awaiting_user` without
rerouting. Resume and Restart reject an unavailable selection until access is
restored or a new `/keep` selects a different agent.

Keep loops track the current trigger comment. Unrelated topic tasks and duplicate
completions cannot advance that turn. If initial or continuation routing schedules
no agent (including an Inbox-ineligible session agent), the loop enters
`awaiting_user` and posts a notice instead of remaining running without a task.
