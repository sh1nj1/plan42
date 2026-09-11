# Agent endpoint health and agent presence

Vendor health checks are optional extensions registered through
`Collavre::AgentHealth.register(vendor, checker)`. A missing checker means
Collavre has no liveness evidence for that vendor; it does not block or skip an
agent call. Checker results are cached on the agent row and are read only for
status presentation.

A checker implements `initialize(agent:)` and `call`, returning an
`AgentHealth::Result` with `online`, `offline`, or `unknown`. It may be supplied
by a satellite engine without adding a dependency from core back to that
engine:

```ruby
class VendorEndpointChecker
  def initialize(agent:)
    @agent = agent
  end

  def call
    Collavre::AgentHealth::Result.new(status: :online)
  end
end

Collavre::AgentHealth.register("vendor_name", VendorEndpointChecker)
```

The probe owns `check_error`; a checker should raise when its own implementation
cannot produce a valid verdict. The probe contains that exception, records the
error state, and never changes dispatch behavior.

Core registers an OpenAI-compatible checker. Once a minute it sends
`GET {gateway_url}/models`, or `GET https://api.openai.com/v1/models` when the
agent has no custom base URL. It uses the same agent or integration API key as
the normal OpenAI client. Both paths use `Collavre::OpenaiEndpoint` to restrict
the shared integration key to the official HTTPS endpoint (including equivalent
host casing, port 443, and trailing slashes). Custom endpoints use only their
per-agent key; keyless dispatch retains its non-secret `local-gateway` placeholder
while the checker omits Authorization. This proves endpoint reachability and, where the
route supports it, authentication; it deliberately does not make a completion
request and therefore does not claim that inference for a particular model
will succeed.

The endpoint checker records `online`, `offline`, `unknown`, or `check_error`.
An unexpected checker exception is contained and displayed as a health-check
error. Results expire after three minutes, and changing the vendor, base URL,
or API key invalidates the cached verdict immediately. Non-administrator URLs
use the same DNS pinning and private-network rejection policy as CLI proxy
requests; redirects are not followed.

Endpoint probes share the dedicated `gateway_health` worker with CLI proxy
probes. For capacity planning, provision at least
`ceil((gateways * 22 + endpoint agents * 11) / 180)` threads: a legacy gateway
can consume two 11-second requests, while one endpoint agent consumes one.

An agent whose runs go through a CLI proxy gateway is only usable while that
gateway can still reach the CLI behind it. Collavre polls each registered
gateway and turns the answer into the online dot next to that agent's avatar.

## The loop

`Collavre::GatewayHealthSweepJob` runs every minute
(`config/recurring.yml`) and enqueues one `Collavre::GatewayHealthProbeJob` per
**active gateway assigned to a CLI proxy agent**. Unassigned gateway rows are
configuration, not a reason for the server to make a perpetual outbound
request. Fanned out rather than looped in one job so a single unreachable host
cannot spend the whole interval and leave the gateways behind it in the loop
unprobed. The probe re-checks the same assignment scope when it starts, so a
gateway unassigned after the sweep does not make a stale outbound request.

Both jobs run on their own `gateway_health` queue (`config/queue.yml`), not on
`default`. A probe blocks on an unreachable host for up to
`OPEN_TIMEOUT + READ_TIMEOUT`, and there is one per gateway every minute, so on
the shared pool a handful of dead gateways would hold every default thread and
stall mailers, broadcasts and notifications behind them.

The dedicated worker defaults to 12 threads and can be sized with
`GATEWAY_HEALTH_THREADS`. Capacity must drain the assigned active-gateway count
within `AgentGateway::HEALTH_TTL`; otherwise a healthy gateway waiting at the
tail can look stale. Size conservatively for the legacy-fallback worst case (22 seconds):
`ceil(assigned active gateways * 22 / 180)`. The default therefore supports at
least 96 assigned active gateways inside the three-minute TTL, with scheduling
margin. Each thread may use a database connection, so the default pool formula
includes this setting; an explicit `DB_POOL` override must include it too.

Both jobs use Solid Queue concurrency controls with `on_conflict: :discard`.
There can be at most one ready or running probe per gateway and one ready or
running sweep. The concurrency semaphore is claimed at enqueue time, so a slow
gateway cannot accumulate another copy on every minute tick. The backlog is
bounded by the active gateway count and drains fairly in queue order; a gateway
that finishes is appended behind gateways still waiting on their first probe.
The semaphore's one-day failsafe exceeds the queue time for thousands of
worst-case probes; normal job completion releases it immediately.

Each probe calls `GET /health/ready` on the gateway
([contract](https://github.com/sh1nj1/cli-openai-proxy/blob/main/docs/health-monitoring.md))
and conditionally writes the verdict onto the `agent_gateways` row:
`health_status`, `health_engines`, `health_error`, `health_checked_at`. Readers
answer from those columns, so no request path ever waits on the proxy.

The response is streamed with a 64 KiB limit before JSON parsing. Only the
bounded fields used for routing (`mode`, counts, and at most 32 engine names and
states) are persisted. A successful response must also carry the proxy's engine
summary (`ready`/`total`) or detailed engine mode; a generic
`{"status":"ok"}` health response is not accepted as proxy identity. Each HTTP
request also has an 11-second wall-clock
deadline, so a chunked response cannot hold a worker indefinitely by sending
small chunks just inside the per-read timeout. A gateway connection or
credential edit immediately invalidates the old verdict, and an in-flight probe
writes only if the row's `updated_at` still matches the configuration it
actually called.

The probe presents the gateway's **completion key**, not its admin key. The
endpoint is unauthenticated, but the proxy only returns per-engine detail to a
caller holding a key from `API_KEYS`; the admin key gates the auth-provisioning
routes and would buy the bare `{ready, total}` summary.

## Statuses

| `health_status` | Written when |
|---|---|
| `unknown` | Never probed, or the proxy answered a rollup this version has no name for. |
| `ok` / `degraded` / `down` | The proxy's own rollup, verbatim. |
| `unreachable` | No verdict at all: DNS, refused connection, a reverse proxy error page, a body that is not JSON. |

A verdict expires after `AgentGateway::HEALTH_TTL` (3 minutes, three sweeps). A
gateway whose probe loop stopped would otherwise keep serving whatever it last
saw, reporting a dead host online until somebody noticed.

A proxy older than the liveness/readiness split answers 404. The probe then
falls back to `GET /health`, which every version has, and records `degraded`
with an explanatory `health_error` — reading that 404 as `unreachable` would
take every agent on an entirely healthy older gateway offline. The fallback
must identify itself as a CLI proxy liveness response; an arbitrary successful
JSON response is recorded as `unreachable`.

## From gateway status to one agent's dot

`User#agent_online?` is `claude_channel_online? || gateway_online?`, and
`gateway_online?` asks `AgentGateway#health_serves_engine?` for the engine this
agent's model spends (`CliProxy::AdapterEngine`).

- `down` and `unreachable` take every agent on the gateway offline.
- `degraded` is the normal steady state of most installs and cannot mean offline
  on its own. What decides is the state of the agent's own engine: only an
  explicit `unauthenticated` reads as offline.
- `unknown` is **not** a failure. A healthy macOS host reports `claude` that way
  forever, because the credential is in a keychain the proxy cannot read.
- Under `mode: "per-user"` the engines live in each worker's `HOME`, so the
  gateway probed a machine the agent's runs never touch. It did prove the
  gateway routes, and calling that offline would black out every per-user agent
  permanently.
- An unrecognized engine, an engine absent from `items`, and the summary-only
  response all fall back to the rollup, which is already `ok` or `degraded`.

## Why it is not chat presence

Chat presence answers "who has this creative open", and it alone drives read
receipts and unread suppression. Agent liveness answers "can this agent be
dispatched to", which is true whether or not anyone is watching. The two are
merged only where the avatar strip paints its dot
(`presence_controller#isParticipantOnline`); `presentIds` reaches
`updateReadReceiptPresence` and the `comments--presence:changed` event
untouched.

The chat popup re-reads `GET /creatives/:id/comments/participants` every 60
seconds to pick up a changed verdict, preserving the rendered menus so an open
profile popup is not torn out from under the user. A confirmed 401/403/404 uses
the same revocation path as the live share event: it disables the composer,
clears or closes the chat, and invalidates the workspace tree.

Agents for a vendor with no registered checker publish no liveness evidence
either way and are shown as unknown rather than asserted online or offline.
