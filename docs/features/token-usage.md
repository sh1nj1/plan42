# Token usage accounting

The profile's **Token usage** link opens `/settings/token-usage`. The same route
accepts `.json`, with `from`, `to`, `period` (`day`, `week`, `month`), `group`
(`owner`, `requester`, `agent`, `model`) and optional `owner_id`, `requester_id`,
`agent_id`, `model` filters. Dates are inclusive in Asia/Seoul, weeks begin on
Monday, and a query spans at most 367 days. SQL aggregation supports SQLite and
PostgreSQL and returns sums of reported values plus missing counts per metric.
Token sums are integers; a wholly unreported metric remains null.

## Collection

`llm_usages` stores one record per RubyLLM assistant response, including tool-loop
intermediates and approval-summary requests. It retains normalized input/output,
cache reads/writes, provider/model, task/creative/topic, source comment IDs,
execution UUID, occurrence time, and a normalization version. Input includes
cache reads and writes, so **do not add cache columns to input again**.

RubyLLM 1.16 exposes uncached input for the supported native providers and
OpenAI-compatible gateways. Normalization v1 reconstructs inclusive input from
those fields. Provider usage is retained when RubyLLM exposes it; streaming
responses can omit the original provider envelope, in which case the RubyLLM
fields and their semantics remain in `raw_usage`. No prompts or credentials are
copied into usage records. An OpenAI cache-write zero synthesized by the library
is treated as unreported unless supported by provider usage.

CLI Proxy responses describe a gateway **run**, potentially many underlying
model calls, so they use `measurement: run`. An OpenClaw adapter that supplies no
usage records an unknown run, never an invented zero. Upstream gateways must
forward cache usage in OpenAI's `prompt_tokens_details.cached_tokens` and
`cache_write_tokens` fields; unreported breakdowns cannot be reconstructed.

The recorder ignores repeated delivery of the same response to its callback and
finalizer. Unique event keys guard duplicate insertion. Actual retries use a new
execution UUID and are counted again. A stream interrupted after reporting usage
retains the latest counters rather than summing cumulative chunks. Existing
activity logs are linked by execution after the call. No-log calls do not create
usage records. Accounting persistence errors are logged without replacing the
provider response.

## Attribution and access

Tasks capture human requesters and original request comments at creation.
Agent replies inherit their task's requesters. Re-anchoring and coalescing queued
tasks union their provenance, preserving the original request. Explicit tool
handoffs and newly created scheduled jobs carry server-derived requester
attribution. Existing schedules without this information remain unknown unless
the scheduled message itself has a human author. Agent ownership is never a
substitute for a missing requester.

The owner is snapshotted at the first instrumented execution and remains stable
through retries, approval resumes, and later ownership changes. Multiple human
requesters are represented by one joint record. `llm_usage_requesters` indexes
membership for filtering and authorization without multiplying usage rows.

People can view records they own or requested, including joint requests.
System administrators can view all records. Filter options are drawn only from
visible records. The API never returns raw usage, prompt contents, or requester
membership arrays. Accounting references intentionally survive deletion of the
source task, user, or activity log; historical missing names display as IDs.

## Rollout and historical records

Run the core engine migration with the normal deployment migration step before
starting the new application. The migration creates empty accounting tables and
adds a task attribution JSON column. It does not rewrite activity logs or infer
historical owners/requesters. The new report begins collecting after rollout;
August's missing cache and provenance data are still unavailable. Existing
activity logs remain available for separate historical analysis, because their
input semantics cannot be reliably normalized retrospectively.

Validation covers interrupted streams, missing vs zero, cache normalization,
multiple model calls, summary calls, retry identity, owner transfer, requester
handoff/coalescing, scoped filters, KST boundaries, HTML/JSON and a mobile browser
flow. PostgreSQL tests use an isolated local test database, not production.
