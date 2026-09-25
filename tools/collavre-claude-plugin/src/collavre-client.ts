import type { CollavreConfig } from "./config.js";

export interface RegisterResult {
  agent_id: number;
  agent_name: string;
  topic_id: number;
  topic_name: string;
  inbox_creative_id: number;
  ws_url: string;
}

export interface RegisterParams {
  // Agent identity (one shared ai_user per human unless overridden).
  agentName: string;
  // Session identity (one Collavre topic per Claude Code session). Stable
  // across --resume so a restart re-binds to the same topic.
  sessionId: string;
  // Human-friendly label for the session topic name (e.g. the cwd basename).
  // Optional; the server falls back to the session id.
  sessionLabel?: string;
}

export interface RegisterBody {
  agent_name: string;
  session_id: string;
  session_label?: string;
  // Legacy composite for servers that only read params[:name]. The new server
  // keys off agent_name/session_id and ignores this.
  name: string;
}

export function buildRegisterBody(params: RegisterParams): RegisterBody {
  const body: RegisterBody = {
    agent_name: params.agentName,
    session_id: params.sessionId,
    name: `${params.agentName}-${params.sessionId}`,
  };
  const label = params.sessionLabel?.trim();
  if (label) {
    body.session_label = label;
  }
  return body;
}

// Only validation/authentication rejections prove no comment was saved.
export class ApprovalRelayRejectedError extends Error {}

export class CollavreClient {
  private baseUrl: string;
  private token: string;

  constructor(config: CollavreConfig) {
    this.baseUrl = config.url.replace(/\/$/, "");
    this.token = config.token;
  }

  async register(params: RegisterParams): Promise<RegisterResult> {
    const res = await fetch(`${this.baseUrl}/api/v1/agent/register`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify(buildRegisterBody(params)),
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(`Register failed (${res.status}): ${body}`);
    }

    return res.json() as Promise<RegisterResult>;
  }

  async quotaTurnCurrent(turn: { task_id: number; execution_generation: string }): Promise<boolean> {
    const url = new URL(`${this.baseUrl}/api/v1/agent/tasks/${turn.task_id}/quota_status`);
    url.searchParams.set("execution_generation", turn.execution_generation);
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${this.token}` },
      signal: AbortSignal.timeout(2000),
    });
    if (res.status === 404) return false;
    if (!res.ok) throw new Error(`Quota status failed (${res.status})`);
    const body = await res.json() as { current?: boolean };
    if (typeof body.current !== "boolean") throw new Error("Invalid quota status");
    return body.current;
  }

  async reply(
    topicId: number,
    text: string,
    taskId: number,
    executionGeneration?: string,
  ): Promise<{ comment_id: number }> {
    const body: Record<string, unknown> = { topic_id: topicId, text, task_id: taskId, execution_generation: executionGeneration };

    const res = await fetch(`${this.baseUrl}/api/v1/agent/reply`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) {
      const respBody = await res.text();
      throw new Error(`Reply failed (${res.status}): ${respBody}`);
    }

    return res.json() as Promise<{ comment_id: number }>;
  }

  // Post an out-of-band informational comment to a topic WITHOUT completing a
  // task (used to surface relayed permission prompts). Unlike reply(), this
  // hits /agent/notify and never touches the task graph. taskId, when present,
  // is the active dispatch's delegated task: the server uses it ONLY to
  // authorize the poster (so prompts on a work topic where this session is not
  // primary_agent still surface) — it is never completed.
  //
  // permissionRequestId, when present, marks this notify as a native
  // tool-permission prompt: the server parks the in-flight delegated task
  // (pending_tool_call) and builds a STRUCTURED approval comment (localized
  // prompt text + approve/deny buttons) from `permission.toolName`/`arguments`.
  // For permission prompts `text` is left empty — the server renders it.
  async notify(
    topicId: number,
    text: string,
    taskId?: number,
    permissionRequestId?: string,
    permission?: { toolName?: string; arguments?: unknown; description?: string },
  ): Promise<{ comment_id: number }> {
    const body: Record<string, unknown> = { topic_id: topicId, text };
    if (taskId !== undefined && taskId !== null) {
      body.task_id = taskId;
    }
    if (permissionRequestId !== undefined && permissionRequestId !== null) {
      body.permission_request_id = permissionRequestId;
    }
    if (permission?.toolName !== undefined) {
      body.tool_name = permission.toolName;
    }
    if (permission?.description !== undefined) {
      body.description = permission.description;
    }
    if (permission?.arguments !== undefined) {
      body.arguments = permission.arguments;
    }

    const res = await fetch(`${this.baseUrl}/api/v1/agent/notify`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) {
      const respBody = await res.text();
      throw new Error(`Notify failed (${res.status}): ${respBody}`);
    }

    return res.json() as Promise<{ comment_id: number }>;
  }

  // Raise an agent-initiated approval request in a topic: the server builds a
  // structured approval comment whose body is `question` verbatim (with the
  // approver gate and approve/deny buttons) and parks the in-flight delegated
  // task, exactly as it does for a relayed tool-permission prompt. requestId
  // rides the same permission_request_id rail, so the human's decision comes
  // back over the agent stream and unblocks the waiting tool call.
  //
  // approverUserId routes the decision to someone other than the token holder;
  // the server rejects an approver who cannot read the creative.
  async requestApproval(params: {
    topicId: number;
    requestId: string;
    question: string;
    taskId?: number;
    approverUserId?: number;
    signal?: AbortSignal;
  }): Promise<{ comment_id: number }> {
    const body: Record<string, unknown> = {
      topic_id: params.topicId,
      text: "",
      approval_question: params.question,
      permission_request_id: params.requestId,
    };
    if (params.taskId !== undefined && params.taskId !== null) {
      body.task_id = params.taskId;
    }
    if (params.approverUserId !== undefined) {
      body.approver_user_id = params.approverUserId;
    }

    const res = await fetch(`${this.baseUrl}/api/v1/agent/notify`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify(body),
      signal: params.signal,
    });

    if (!res.ok) {
      const respBody = await res.text();
      const message = `Approval request failed (${res.status}): ${respBody}`;
      if ([400, 401, 403, 404, 422].includes(res.status)) {
        throw new ApprovalRelayRejectedError(message);
      }
      throw new Error(message);
    }

    return res.json() as Promise<{ comment_id: number }>;
  }

  async unregister(
    agentId: number,
    topicId?: number,
    sessionId?: string,
  ): Promise<void> {
    const url = new URL(`${this.baseUrl}/api/v1/agent/${agentId}`);
    if (topicId !== undefined) {
      url.searchParams.set("topic_id", String(topicId));
    }
    // Send the stable session id so the server can drop THIS session's
    // presence row even when the topic_id no longer resolves (stale/archived).
    // Without it, destroy falls back to topic.session_id and, on a nil topic,
    // can't identify the exiting session — leaving its own row to masquerade as
    // a live sibling and pin routing_expression until the 45s lease reap.
    if (sessionId !== undefined) {
      url.searchParams.set("session_id", sessionId);
    }
    await fetch(url.toString(), {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${this.token}`,
      },
    }).catch(() => {
      // Best-effort cleanup on shutdown
    });
  }
}
