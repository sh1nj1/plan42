import type { Server } from "@modelcontextprotocol/sdk/server/index.js";
import type { CollavreClient } from "./collavre-client.js";
import type { AgentEvent } from "./cable-subscriber.js";
import { shouldHandleDispatch } from "./dispatch-filter.js";
import type { QuotaState } from "./quota-state.js";
import type { PermissionCoordinator, Behavior } from "./permission.js";
const PERMISSION_DECISION_METHOD = "notifications/claude/channel/permission";

// Tracks the most recently forwarded dispatch so an incoming permission_request
// (which carries no topic or task) can be surfaced into the right topic AND
// authorized as the dispatched agent. A Claude Code session processes one turn
// at a time, so the last forwarded dispatch is the turn whose tool is now
// awaiting permission.
//
// taskId is the dispatch's delegated task: the server authorizes /notify
// against it so prompts raised on a *work* topic (where this session is not the
// topic's primary_agent, having been matched via routing_expression) still
// surface — topic.primary_agent alone would 403 there.
//
// defaultTopicId is the registration inbox topic. After a turn ends (the reply
// tool is called) topicId/taskId reset to this default so a subsequent locally-
// initiated turn's prompt surfaces in the inbox instead of leaking into the
// just-finished work topic (and so a normal reply there is not consumed as a
// permission decision).
export interface ActiveContext {
  topicId: number | null;
  taskId: number | null;
  defaultTopicId: number | null;
  // This session's own session topic (from register). Fixed for the process
  // lifetime: used to ignore dispatches routed to a sibling session's mapped
  // topic over the shared per-agent stream.
  sessionTopicId: number | null;
}

async function sendPermissionDecision(
  server: Server,
  requestId: string,
  behavior: Behavior,
): Promise<void> {
  await server.notification({
    method: PERMISSION_DECISION_METHOD,
    params: { request_id: requestId, behavior },
  });
}

export function makeEventHandler(
  server: Server,
  client: CollavreClient,
  coordinator: PermissionCoordinator,
  active: ActiveContext,
  debug: boolean,
  quotaState: QuotaState,
) {
  return async (event: AgentEvent): Promise<void> => {
    // A structured permission decision (approve/deny button click relayed by the
    // server). It carries an explicit request_id + behavior — no text parsing.
    // The broadcast reaches every session sharing this agent; only the session
    // that surfaced this request_id claims it and forwards it to Claude Code.
    if (event.type === "permission_decision") {
      const { request_id, behavior } = event;
      if (!request_id || (behavior !== "allow" && behavior !== "deny")) return;
      if (!coordinator.claim(request_id)) {
        if (debug) {
          process.stderr.write(
            `[collavre] Ignoring permission_decision for unknown/foreign request_id=${request_id}\n`,
          );
        }
        return;
      }
      process.stderr.write(
        `[collavre] Permission decision: ${behavior} (request_id=${request_id})\n`,
      );
      try {
        await sendPermissionDecision(server, request_id, behavior);
      } catch (err) {
        process.stderr.write(
          `[collavre] Failed to send permission decision: ${err instanceof Error ? err.stack : err}\n`,
        );
      }
      return;
    }

    if (event.type !== "dispatch" || !event.comment) {
      if (debug) {
        process.stderr.write(
          `[collavre] Ignoring non-dispatch event: ${JSON.stringify(event).slice(0, 200)}\n`,
        );
      }
      return;
    }

    const topicId = event.comment.topic_id;

    // Ignore dispatches that belong to a sibling session's mapped topic. A
    // shared agent fans out to many session topics, and every session on this
    // agent's stream hears them all — only the owning session answers its own
    // session topic. Work/project topics (session_topic=false) pass through;
    // the server's atomic task claim dedups if two sessions both take one.
    if (
      !shouldHandleDispatch({
        sessionTopic: event.session_topic,
        dispatchTopicId: topicId,
        mySessionTopicId: active.sessionTopicId,
      })
    ) {
      if (debug) {
        process.stderr.write(
          `[collavre] Ignoring dispatch for sibling session topic #${topicId} (mine=#${active.sessionTopicId})\n`,
        );
      }
      return;
    }

    process.stderr.write(
      `[collavre] Dispatch: comment #${event.comment.id} by ${event.comment.author_name} (id=${event.comment.author_id}) task_id=${event.task_id ?? "none"}\n`,
    );

    // Record the active turn's topic AND delegated task so a permission_request
    // relayed during it can be surfaced into this topic and authorized as the
    // dispatched agent (work topics where this session is not primary_agent).
    await quotaState.prune(turn => client.quotaTurnCurrent(turn));
    active.topicId = topicId;
    active.taskId = event.task_id ?? null;

    try {
      const meta: Record<string, string> = {
        topic_id: String(event.comment.topic_id),
        comment_id: String(event.comment.id),
        author: event.comment.author_name,
        author_id: String(event.comment.author_id),
      };
      if (event.task_id != null) {
        meta.task_id = String(event.task_id);
        if (event.execution_generation) meta.execution_generation = event.execution_generation;
      }
      await server.notification({
        method: "notifications/claude/channel" as const,
        params: {
          content: event.comment.content,
          meta,
        },
      });
      if (event.task_id && event.execution_generation) {
        quotaState.add({ task_id: event.task_id, execution_generation: event.execution_generation });
      }
      process.stderr.write(`[collavre] Notification sent OK\n`);
    } catch (err) {
      process.stderr.write(
        `[collavre] Failed to forward message: ${err instanceof Error ? err.stack : err}\n`,
      );
    }
  };
}
