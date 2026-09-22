# Session quota recovery

Session recovery belongs to the server. A failed model does not need to call a
cron tool. This feature depends on the task suspend/resume foundation.

## CLI proxy contract

The inspected proxy release (`20260910T053758Z-602550`) maps `provider_quota` to
`insufficient_quota` and transient upstream failures to `rate_limit_exceeded`.
Only the former enters session recovery, and only for the `cli_proxy` vendor.
Explicit billing, credit-balance and account-disabled errors retain the normal
failure path. General OpenAI API quota failures do not enter session recovery.

Non-streaming responses carry HTTP 429 and a `Retry-After` delta in seconds.
The installed proxy's streaming path already flushed HTTP 200 and sends an SSE
error envelope with `type`/`code`; it drops `retryAfterSeconds`. RubyLLM 1.16.0
preserves that envelope while rewriting the error status to 400. Classification
therefore uses the structured error code rather than the HTTP status.

Valid delta seconds and HTTP-date headers schedule the original task for the
reset plus 5–30 seconds of positive jitter. Past, invalid, absent or more than
14-day resets use bounded 30/60/120-minute backoff. A replay of the original task
is the probe; the health endpoint does not prove model quota is available.
Three automatic attempts are allowed per agent until a successful turn clears
the counter. Further quota failures block automatic retries, including new
scheduler requests. Operators should resolve the subscription/account issue
before clearing `quota_retry_exhausted`, `quota_retry_count` and
`quota_blocked_until` on the agent.

The agent block and task suspension commit together. TaskResumer owns the
durable scheduled job, locks, task retry limit and recurring reconciliation.
New requests received during a block become suspended task rows. The execution
entry point checks again to cover jobs enqueued before the block.

## Claude Channel

The repository plugin started at 0.1.0. The inspected CLI reports Claude Code
2.1.267. Its supported `StopFailure` event accepts the `rate_limit` matcher;
see the [official hook reference](https://code.claude.com/docs/en/hooks#stopfailure).
The inspected environment has no registered installation of the Collavre plugin;
its live installation on other machines was not inferred from source version.

The hook sends `POST /api/v1/agent/tasks/:id/suspend` with reason `quota` and the
execution generation from the dispatch. It uses the plugin's existing bearer
authentication; the server checks agent ownership, creative permission, task
state and generation under locks. Duplicate suspension requests do not extend
the deadline or spend another retry. Reply tools echo the original dispatch
generation too, rather than replacing an old reply's generation with the newest
one stored by the plugin.

Only a session/usage-cap message is classified as quota. Ordinary requests-per-
minute failures and billing errors are ignored. Reset timestamps must include a
date and timezone; ambiguous text such as "resets 5pm" uses bounded backoff.

The hook cannot identify the failing task when multiple dispatched tasks or
multiple live MCP sessions share one working directory. It refuses that
ambiguity. Older Claude versions, missing hooks, ambiguous attribution and
failed hook HTTP delivery cannot establish a quota reset; existing offline and
stuck-task recovery remain the fallback, without a promised quota-timed resume.
The CLI proxy server-side path does not have this hook dependency. To enable
Channel quota recovery, update the plugin, restart the Claude session, and use
one outstanding dispatched turn per working directory.
