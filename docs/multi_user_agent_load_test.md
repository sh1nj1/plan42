# Multi-user agent load test

Capacity target: **10 people, each driving 4 agents at the same time**. That is
40 concurrent agent turns while those people keep using the UI.

The test drives the real production path: login, then `POST` a comment, then
the orchestrator, Solid Queue (`ai_agents`), RubyLLM, and the HTTP stream. The
model is a local fake. Agents point their `gateway_url` at
`Perf::FakeLlmServer`, an OpenAI-compatible endpoint that holds every turn
open for a fixed time (default 20s), like a real provider stream. The fake also
counts how many turns are in flight at once. No app code changes are needed,
and the test costs nothing.

## Shape

- 4 shared agents (`perf-agent-N`).
- 10 people (`perf-user-N`). Each person owns a workspace creative with one topic
  per agent, and each topic is pinned to its agent. A topic runs one turn at a
  time, so separate topics are the only way one person can run 4 turns at once.
- Each person has their own client address (`X-Forwarded-For` from TEST-NET-2),
  so per-IP limits see 10 people instead of one.
- All 40 messages are posted at the same moment. Each person keeps reading
  their chat (`GET /creatives/:id/comments?topic_id=`) every 0.5s until every
  turn has finished.

## Checks

| Check | Target | Why |
|---|---|---|
| all turns completed | 40 `done` | nothing dropped or failed |
| all turns streamed at once | peak in-flight ≥ 40 | 40 turns actually run in parallel |
| agent start p95 | ≤ 5s | time from posting a message to the agent starting its turn |
| comment post p95 | ≤ 2s | sending a message stays responsive under a burst |
| UI read p95 | ≤ 1s | other UI requests stay responsive during the load |
| request errors | 0 | |

## Running

```bash
script/perf/run_local.sh                                  # 10 x 4, 20s turns
PERF_USERS=2 PERF_AGENTS=2 PERF_LLM_SECONDS=3 script/perf/run_local.sh   # smoke
AI_AGENT_THREADS=40 RAILS_MAX_THREADS=5 script/perf/run_local.sh         # try capacity knobs
```

`run_local.sh` boots a production-like server in the `desktop` environment
(Solid Queue inside Puma, Solid Cache, multi-database SQLite) with an isolated
data dir in `tmp/perf/data`. It then runs the load and stops the server. The
script exits 1 when any check fails. The JSON report is written to `tmp/perf/`.

To test another server that shares this app's database (for example Postgres
through `DATABASE_URL`), run the driver directly in that environment:

```bash
PERF_BASE_URL=http://127.0.0.1:3000 bin/rails runner script/perf/multi_user_agents.rb
```

Knobs: `PERF_USERS`, `PERF_AGENTS`, `PERF_LLM_SECONDS`, `PERF_TIMEOUT`,
`PERF_START_P95`, `PERF_POST_P95`, `PERF_WEB_P95`, `PERF_REPORT`.

## Baseline (main @ 59bd0b3a0, default config, Apple Silicon laptop)

| Metric | Default config | `AI_AGENT_THREADS=40` |
|---|---|---|
| turns done | 40/40 | 40/40 |
| peak concurrent turns | **12** | 39 |
| agent start p50 / p95 | 23.7s / **65.2s** | 2.8s / **23.4s** |
| comment post p50 / p95 | 2.05s / **2.74s** | 1.94s / **3.02s** |
| UI read p50 / p95 / max | 0.02s / 0.05s / 1.97s | 0.02s / 0.06s / 2.65s |
| verdict | FAIL | FAIL |

What the baseline shows:

1. **The `ai_agents` worker caps the whole server at 12 turns.** The other 28
   turns wait in the queue, and start in waves of one turn length (20s).
2. **The per-agent cap (`max_concurrent_jobs`, default 5) leaks under a
   burst.** With threads raised, 39 of 40 turns still ran at once, although the
   4 agents × 5 limit should allow only 20. `ResourceTracker#reserve!` does a
   read-modify-write on a cached Set, so concurrent reservations overwrite each
   other. The Scheduler also reads that count when it enqueues, before any job
   has reserved. The few turns it did catch waited the full 30s `:busy` backoff,
   and that wait is the 23s p95.
3. **40 simultaneous message posts queue on 3 Puma threads.** Each post runs
   about 80 queries, so a burst pushes post p95 over 2s.
4. UI reads stay fast while turns stream. LLM streaming happens on job threads,
   not on web threads.
