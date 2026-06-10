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

  async reply(
    topicId: number,
    text: string,
    taskId: number,
  ): Promise<{ comment_id: number }> {
    const body: Record<string, unknown> = { topic_id: topicId, text, task_id: taskId };

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
    permission?: { toolName?: string; arguments?: unknown },
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
