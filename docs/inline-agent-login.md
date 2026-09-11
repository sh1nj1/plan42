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
session from the proxy. Custom provider base URLs remain on the full connection
screen. Session starts claim an attempt ID before contacting the proxy; only
the latest initiated attempt can store its response. Starting another attempt
also invalidates the previous session and its authorization.

After the server observes successful authorization, a locked replay claim
queues the original request once through the scheduler. Permissions and topic
assignment are checked again; scheduler rejection leaves the claim available
for another attempt. The retry carries the original human workspace principal
and strips turn-scoped delivery metadata. Requests that already emitted a
chunk, previously handed off during an approval continuation, were cancelled,
or whose source message was moved/deleted are not automatically replayed.
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
callback abandons that login claim as well. Successful replies and turns waiting
for tool approval retain the normal completion path.
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
