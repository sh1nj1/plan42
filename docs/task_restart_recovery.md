# Offline and worker restart recovery

Interrupted work uses the same Task and the common suspension/resumption path.
The server never posts a new user request to restart an interrupted turn.

## Channel presence

`CancelOfflineDelegatedTasksJob` retains its name for already-persisted jobs,
but suspends work with `agent_offline` after the 30-second reconnect grace.
The presence check and suspension hold the agent row lock shared by subscribe
and unsubscribe. A reconnect either prevents suspension or observes it and
enqueues `ResumeSuspendedTasksJob` after its presence transaction commits.
Each task carries a `trigger_event_payload.offline_grace_until` deadline: reconnect clears the old
deadline and a new disconnect records a fresh one. Old queued cleanup jobs
therefore cannot shorten a later disconnect's grace period. Legacy queued
cleanup jobs without a deadline establish one before suspending.
Session topics require their original session; a live sibling may service
shared topics but cannot take over a disconnected private session topic.

`OfflineTaskSweepJob` runs every minute to cover ActionCable crashes that never
call unsubscribe. It schedules the same full grace period rather than
immediately suspending a turn during a transient disconnect. Endpoint and
gateway probes enqueue recovery for online agents that have suspended work.
Every positive probe can retry this trigger, so enqueue failure does not
require a second offline-to-online transition.

## Solid Queue ownership

The implementation targets the installed Solid Queue 1.7.0 behavior:

- Workers claim jobs in `solid_queue_claimed_executions`, linked to a process.
- Process heartbeats default to 60 seconds. The alive threshold defaults to
  five minutes. The supervisor prunes expired processes and records
  `ProcessPrunedError` on their jobs; a known terminated worker produces
  `ProcessExitError`, orphaned claims produce `ProcessMissingError`, and an
  async worker thread exit produces `ThreadTerminatedError`.
- The application records the Active Job ID in the task's
  `trigger_event_payload.execution_job_id` when execution starts.
- `RecoverInterruptedTasksJob` only recovers a `running` task with
  a matching failed `Collavre::AiAgentJob` and one of those process
  failures. A surviving claim, missing owner metadata, missing job, ready job,
  or ordinary application error does not authorize recovery.

Worker startup schedules recovery. The real `on_worker_stop` hook schedules
another sweep after the drain timeout. It does not install a signal handler:
Solid Queue retains control of TERM and forced termination. For AI workers,
the stop hook shuts down the execution pool and waits for it to drain before
process deregistration. The supervisor still applies its normal shutdown
timeout and forced exit. This prevents deregistration from returning a
still-executing job to the ready queue. A forced exit instead leaves ownership
evidence for recovery. Stop hooks run **before** the normal worker drain, so
suspending and immediately resuming there would race the provider call.

The recurring recovery sweep runs every minute. Known process exits can
recover on the next sweep. Unobserved machine loss waits for Solid Queue's
heartbeat failure detection; stale heartbeat alone is not treated as an
application authorization to steal work. Channel turns still in `running`
are recovered when their recorded worker has a confirmed process failure;
they have not reached delegation or broadcast. Once `delegated`, channel
turns remain the responsibility of the presence policy. The recovery row
lock rechecks the status so concurrent delegation prevents redispatch.
An unsupervised worker waits for its AI pool to finish; deployments should use
the configured supervisor to retain a bounded graceful shutdown.
Tasks started before execution ownership was recorded retain the existing
stuck-task fallback; boot does not guess which process owned them.
