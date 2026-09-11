# Inline engine login

A CLI Proxy completion with `error.code = engine_unauthenticated` and an
allowlisted auth engine creates a login card on its reply comment. RubyLLM
preserves this body for both HTTP errors and SSE errors; the latter is mapped
to a 400 exception by RubyLLM, so classification uses the machine code.
Other provider errors retain the existing error behavior. Auth status is not
used as a preflight gate (`unknown` is not proof of missing credentials).

The shared comment contains only a localized notice and a lazy frame URL.
The frame and every session request recheck creative access, the original
message, the current gateway and the recorded workspace. Per-user login is
restricted to that workspace's user; shared login is restricted to the agent
owner or a system administrator. Other participants receive an explanation.

The existing connection screen and inline card share the auth controller.
Device codes are displayed and polled; pasted OAuth codes and API keys are
sent directly in `auth_secret` to a CSRF-protected endpoint. They never become
chat messages. Only the attempt/session IDs, initiating user and authorization
result are stored with the task. Responses are private and not cached. Chat refreshes
preserve the live login form, and a rebuilt card can recover its pending
session from the proxy. Status responses and errors are ignored if a newer login
session has started while the request was in flight. Custom provider base URLs
remain on the full connection screen. Session starts claim an attempt ID before contacting the proxy; only
the latest initiated attempt can store its response. Starting another attempt
also invalidates the previous session and its authorization. Cancellation
invalidates browser polling immediately, before sending DELETE,
and revokes the server session before contacting the proxy, so stale polls and
submissions cannot authorize a replay even if the proxy cancellation fails.
Superseded login and cancellation responses, including errors, cannot replace
the current session or its polling. Within a matching session, observed authorization
is monotonic: a late pending/failed snapshot cannot revoke it. Only cancellation
or a new attempt clears authorization.

After the server observes successful authorization, a locked replay claim
queues the original request once through the scheduler. Current routing is matched
again before scheduling and admission, including permissions, mentions, topic
assignment and routing expressions. For coalesced turns, current public comments
still in the recorded creative/topic also participate in matching; a mention in
one of those comments can select the recorded agent even when the anchor does not.
Merged comment IDs survive replay so the normal trigger renderer delivers their
current text and attachments with the anchor. Deleted, private, approval, or moved
comments cannot authorize the replay or contribute to its trigger.
The recorded agent must still be selected; scheduler rejection leaves the claim available
for another attempt. The retry carries the original human workspace principal
and strips turn-scoped delivery metadata. An explicit principal (including nil)
is preserved; shared replays without one use the source commenter through the
normal principal resolver, not the manager who completed login. Requests that
already emitted a chunk, previously handed off during an approval continuation,
were cancelled, or whose source message was moved/deleted are not automatically
replayed.
Once replay is claimed, session mutations are rejected, including responses
from requests that were already in flight. Queued replays include the original
task ID so cleanup can run even if the card or initiating user is deleted.
Queued replays carry only identifiers and revalidate the request at execution.
If validation rejects a claimed replay, it clears the claim, disables automatic
retry for that turn, refreshes the card with a failure notice, and explicitly
runs the terminal task's completion callbacks. An abandoned replay puts its
trigger loop in `awaiting_user` and posts a notice even when no reply card
remains, without evaluating the login notice as an agent result.
Admitted replays, including queued waiters, retain their original login task ID.
If they are cancelled, fail, or escalate without completing, their terminal
callback abandons that login claim as well. Successful replies mark their linked
login claims completed and disable retry while preserving the resumed notice.
Later source/card withdrawal cannot rewrite those historical claims as abandoned.
Only the reply task drives loop completion; settled login cards never do.
Completion requires a persisted reply or review result. An empty response abandons
its linked claims and cannot retain loop completion ownership.
A second authentication failure or a failed provider handoff is not successful
completion, and turns waiting for tool approval keep their claims pending.
Repeated authentication carries every ancestor login claim into the next admitted
replay, so its eventual success or failure settles the entire chain of cards.
Settled cards remain readable by reply viewers even after source invalidation,
without enabling session actions. Coalescing queued turns
transfers all login claims to the survivor in the same transaction; superseded
waiters do not abandon requests that remain queued. The survivor settles every
inherited claim if it later ends without a result.
Withdrawing a source (deletion, privacy change, creative/topic move, or
conversion to an approval surface) also cancels approval-paused replays, releases
their held resources, and drains the topic queue. Their remaining approval cards cannot execute tools
or enqueue a continuation after cancellation. Bulk topic moves settle pending login
turns only after the move commits. If their topic has left the original creative,
the loop abandonment notice stays in that creative's main topic.
After restoring access or authentication, the requester must send a new message.

Verification covers HTTP/SSE classification with RubyLLM's real parser,
workspace and session isolation, replay claims, permission revocation,
scheduler rejection, and browser paste-code/device-code flows with a stub
proxy. Real vendor OAuth approval and Linux worker isolation require the
corresponding live proxy deployment.
