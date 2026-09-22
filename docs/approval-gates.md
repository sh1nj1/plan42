# Human approval gates

Native Collavre agents can call `approval_request` to ask a person for a decision
and suspend the current task. Enable it in the agent's tools, or discover and run
it through `meta_tool`:

```json
{
  "action": "run",
  "tool_name": "approval_request",
  "arguments": {
    "question": "Publish the reviewed release notes?",
    "approver_user_id": 123
  }
}
```

`question` is required and supports Markdown. `approver_user_id` is optional and
defaults to the triggering comment's author. The approver must be a human with
read access to the creative. If the trigger has no human author, specify an
eligible person explicitly.

The designated person sees the existing approve/deny buttons and an optional
reason field. Either response resumes the original call with:

```json
{"decision":"denied","reason":"Revise the release date first","decided_by":123}
```

A denial is a normal tool result: reconsider the plan and do not perform the
denied action. No response leaves the task pending indefinitely. Automatic
expiration, automatic denial, multiple-choice options, and automatic slot
reclamation are not part of this feature. Existing task cancellation remains
available; a cancelled or superseded request cannot resume work.

## Execution and recovery

The native `AiClient` intercepts direct calls and `meta_tool run` calls before
execution. `ApprovalGateHandler` atomically records a provider-neutral conversation
snapshot, original tool-call ID, pending task state, and approval comment. Images,
completed tool results, and provider thinking signatures survive resumption.

The response is injected as a result for that exact call, without asking the model
to repeat it or executing a tool server-side. Other unfinished calls in the same
batch receive an explicit not-executed result so the model can reconsider them.
New comments posted during the pause are not recorded as read by this snapshot.

Decision recording locks both task and comment. Duplicate clicks cannot schedule
multiple decisions. The resume job uses the existing agent lifecycle with an
atomic pending-to-running admission check; duplicate delivery cannot start a
second worker. Before admission, an interrupted resume can be retried.

This version supports native Collavre LLM turns, including their dynamic meta-tool
calls. External MCP sessions and delegated Claude Channel/OpenClaw processes do
not have a native conversation to restore and cannot use this tool to suspend;
the tool returns an explicit error there. Existing Claude Channel permission
prompts and automatic tool approvals retain their separate behavior.
