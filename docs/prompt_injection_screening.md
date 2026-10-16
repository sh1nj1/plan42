# Prompt-injection screening

`Collavre::Screening` checks the text of an agent turn before the agent
receives it, when the turn runs on behalf of someone other than the agent's
owner. A shared agent runs on its owner's machine, credentials, and workspace,
so another collaborator's message is untrusted input to that agent.

Screening is off by default. Turn it on with the `screening_enabled` system
setting after configuring `TYPESAFE_API_KEY` (and optionally
`TYPESAFE_API_BASE`).

## Which turns are screened

`Screening::Scope` screens a turn that carries text from anyone other than the
agent's owner. It checks both the turn's principal
(`AiAgent::WorkspaceAuthentication#workspace_user`, carried through A2A
chains) and the authors of the comments the turn carries: the anchor, the
merged comments and a workflow source message. The principal alone is not
enough: a cron or A2A comment can arrive with the owner as fallback principal
while another person's agent wrote it.

| Case | Result |
|---|---|
| Principal is another person | Screened |
| Carried but unverifiable principal (`workspace_user_id: nil`) | Screened |
| An author other than the owner, the agent, or the owner's other agents | Screened |
| Owner principal and trusted authors, or a system turn with neither | Skipped |

## Who screens

`Screening::ScreenerResolver` always starts from the system screener (Typesafe
Jev with the deployment key). A judge-capable agent shared on the turn's
creative, or an ancestor, with feedback or higher can customize this:

- owned by the protected agent's owner: replaces the system screener;
- owned by anyone else: screens alongside it, and the stricter verdict wins.

A creative admin can share their own judge, so a judge owned by someone else
can only make screening stricter. The question and the policy are server
constants (`Screening::QUESTIONS`, `POLICY_VERSION`). A judge chooses only the
model.

## Verdicts

The screener answers a probability. `screening_threshold` (default 0.5) flags
and `screening_block_threshold` (default 0.9) blocks. A screener that fails,
times out, or answers malformed output yields `error`, never `passed`.
Severity is `blocked > error > flagged > passed`: a definite block by one
screener is not overridden by the owner's approval of another screener's error.

| Verdict | Claude Channel |
|---|---|
| passed | Delivered |
| flagged | Not delivered: the session's local tools are outside the server's approval gates |
| error | Paused for the agent owner's approval |
| blocked | Not delivered; the task fails and the sender is told |

A notice that cannot be posted is logged; the turn still ends as blocked.

Each screener's verdict is recorded as a `screening` task action with the
model, policy version and a SHA-256 of the screened content. Verdicts are not
cached.

## Owner approval

An `error` raises `ScreeningPendingError`. `AiAgent::ScreeningApprovalHandler`
pauses the task with `pending_tool_call.kind = "screening"` and posts an
approval-gate comment whose approver is the **agent's owner**. The creative
owner is not used: the sender may own the creative and must not approve their
own turn. An owner who cannot read the creative cannot decide, so the turn is
blocked instead of pausing until someone stops it.

When one screener errors and another flags, the approval request says so, and
an approved turn is still handled as flagged.

Approving resumes the same task (`ApprovalGateResumeJob`). The approval
applies only to content with the recorded digest; changed content is
screened again. Denying fails the task and tells the sender, even if
screening was turned off while the turn waited.

## Claude Channel

`AiAgentJob` screens a Claude Channel turn while it is still `running`,
before it marks the task `delegated`, so an error can pause it for approval.
The adapter then sends exactly the screened text
(`ClaudeChannelAdapter.trigger_content`).
