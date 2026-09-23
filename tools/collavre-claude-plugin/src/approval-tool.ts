// The `approval_request` MCP tool: ask the human in Collavre to approve or deny
// something, and block this tool call until they decide.
//
// Kept out of index.ts (which owns transport wiring) so the whole flow —
// validation, the one-open-request rule, the relay, the wait and the re-await —
// is unit-testable against fakes.

import {
  formatApprovalDecision,
  formatApprovalPending,
  formatApprovalUnknown,
  type ApprovalWaiter,
} from "./approval.js";
import type { PermissionCoordinator } from "./permission.js";

export interface ApprovalRelayParams {
  topicId: number;
  requestId: string;
  question: string;
  taskId?: number;
  approverUserId?: number;
}

export interface ApprovalToolDeps {
  // Posts the approval request into the topic as a structured approval comment.
  relay(params: ApprovalRelayParams): Promise<unknown>;
  waiter: ApprovalWaiter;
  // Approval request ids are ALSO tracked as pending permissions so the
  // pull-on-resubscribe replay redelivers a decision clicked while the
  // WebSocket was down — the same guarantee relayed tool prompts get.
  coordinator: PermissionCoordinator;
  // The dispatch currently being served. The request must land in that topic
  // (and is authorized against that task), exactly as a relayed tool prompt is.
  active: { topicId: number | null; taskId: number | null };
  waitMs: number;
  newRequestId(): string;
  log?(message: string): void;
}

// A type alias, not an interface: the MCP SDK's CallToolResult carries an index
// signature, and only an object *type* gets the implicit index signature needed
// to satisfy it.
export type ApprovalToolResult = {
  content: { type: "text"; text: string }[];
  isError?: true;
};

function ok(text: string): ApprovalToolResult {
  return { content: [{ type: "text", text }] };
}

function fail(text: string): ApprovalToolResult {
  return { content: [{ type: "text", text }], isError: true };
}

function optionalId(value: unknown): number | null | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

export async function runApprovalRequest(
  args: unknown,
  deps: ApprovalToolDeps,
): Promise<ApprovalToolResult> {
  const record = args && typeof args === "object" ? (args as Record<string, unknown>) : {};

  // Re-await: continue waiting on a request whose previous wait window elapsed.
  const resume = typeof record.request_id === "string" ? record.request_id.trim() : "";
  if (resume) {
    if (!deps.waiter.has(resume)) return fail(formatApprovalUnknown(resume));
    return await awaitDecision(resume, deps);
  }

  const question = typeof record.question === "string" ? record.question.trim() : "";
  if (!question) {
    return fail(
      "question must be a non-empty string — state the concrete decision you need from the human.",
    );
  }

  // One undecided request at a time: a second one would post a duplicate gate
  // into the topic that nobody needs to answer. The open id is named so the
  // model re-awaits it instead.
  const [alreadyOpen] = deps.waiter.openIds();
  if (alreadyOpen) {
    return fail(
      `An approval request is already open (request_id="${alreadyOpen}"). ` +
        `Call approval_request with request_id="${alreadyOpen}" to wait for that decision ` +
        "instead of raising another one.",
    );
  }

  const topicId = deps.active.topicId;
  if (topicId == null) {
    return fail(
      "No active Collavre topic — approval_request only works while serving a Collavre message.",
    );
  }

  const approverUserId = optionalId(record.approver_user_id);
  if (approverUserId === null) {
    return fail("approver_user_id must be a positive integer user id.");
  }

  const requestId = deps.newRequestId();
  deps.coordinator.add(requestId);
  deps.waiter.open(requestId);
  try {
    await deps.relay({
      topicId,
      requestId,
      question,
      taskId: deps.active.taskId ?? undefined,
      approverUserId,
    });
  } catch (err) {
    // The request never reached the topic, so nothing can decide it: stop
    // tracking it rather than leaving it to block the next request.
    deps.waiter.cancel(requestId);
    deps.coordinator.claim(requestId);
    return fail(
      `Failed to raise the approval request: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  deps.log?.(`[collavre] approval_request raised in topic #${topicId} (request_id=${requestId})`);
  return await awaitDecision(requestId, deps);
}

async function awaitDecision(
  requestId: string,
  deps: ApprovalToolDeps,
): Promise<ApprovalToolResult> {
  const decision = await deps.waiter.wait(requestId, deps.waitMs);
  if (!decision) return ok(formatApprovalPending(requestId, deps.waitMs));

  deps.log?.(`[collavre] approval_request ${decision.behavior} (request_id=${requestId})`);
  return ok(formatApprovalDecision(decision));
}
