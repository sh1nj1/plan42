import type { CollavreConfig } from "./config.js";
import type { ApprovalWaiter } from "./approval.js";
import type { PermissionCoordinator } from "./permission.js";
import type { ActiveContext } from "./dispatch-handler.js";

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
): Promise<{ comment_id: number }> {
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
  if (active.taskId === taskId && active.topicId === topicId) {
    active.topicId = active.defaultTopicId;
    active.taskId = null;
  }
  return result;
}
