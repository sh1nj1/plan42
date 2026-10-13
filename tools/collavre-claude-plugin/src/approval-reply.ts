import type { CollavreConfig } from "./config.js";
import type { ApprovalWaiter } from "./approval.js";
import type { PermissionCoordinator } from "./permission.js";
import type { ActiveContext } from "./dispatch-handler.js";
import { isBenignReplyDedup } from "./collavre-client.js";

// Snapshot before the HTTP request. openIds includes decisions cached after
// pending, but excludes decisions already returned to the model by wait().
export async function replyWithApprovalHandoff(
  config: Pick<CollavreConfig, "url" | "token">,
  topicId: number,
  text: string,
  taskId: number,
  generation: string,
  waiter: ApprovalWaiter,
  coordinator: PermissionCoordinator,
  active: ActiveContext,
): Promise<{ handled: true; comment_id: number } | { handled: false; reason: string }> {
  const currentTurn = active.taskId === taskId && active.topicId === topicId;
  const approvalIds = waiter.openIds();
  const permissionIds = currentTurn
    ? coordinator.pendingIds().filter(id => !approvalIds.includes(id))
    : [];
  const res = await fetch(`${config.url.replace(/\/$/, "")}/api/v1/agent/reply`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${config.token}` },
    body: JSON.stringify({
      topic_id: topicId, text, task_id: taskId, execution_generation: generation,
      pending_approval_ids: approvalIds,
    }),
  });
  // 409 has two causes and only one is benign. Sessions in the SAME working
  // directory share one agent, so a dispatch fans out to all of them and each
  // replies with the same task_id; the server's atomic claim lets one win and
  // marks the others' refusal "already_completed". Any other 409 (cancelled,
  // failed, recovered, resumed under a newer generation) means nobody answered,
  // so it is raised like every other failure and local approvals stay tracked.
  if (res.status === 409) {
    const body = await res.text();
    if (!isBenignReplyDedup(body)) throw new Error(`Reply failed (409): ${body}`);
    // The sibling's reply concluded this turn: drop its context, but leave
    // approvals alone — the server acknowledged none of them for us.
    clearActiveTurn(active, topicId, taskId);
    return { handled: false, reason: body };
  }
  if (!res.ok) throw new Error(`Reply failed (${res.status}): ${await res.text()}`);
  const result = await res.json() as { comment_id: number; pending_approval_ids?: string[] };
  // A new dispatch can arrive before this HTTP response. Never clear its
  // context or requests when finishing the old turn.
  for (const id of result.pending_approval_ids ?? []) {
    if (approvalIds.includes(id)) {
      waiter.cancel(id);
      coordinator.claim(id);
    }
  }
  for (const id of permissionIds) coordinator.claim(id);
  clearActiveTurn(active, topicId, taskId);
  return { handled: true, comment_id: result.comment_id };
}

function clearActiveTurn(active: ActiveContext, topicId: number, taskId: number): void {
  if (active.taskId === taskId && active.topicId === topicId) {
    active.topicId = active.defaultTopicId;
    active.taskId = null;
  }
}
