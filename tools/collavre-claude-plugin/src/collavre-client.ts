import type { CollavreConfig } from "./config.js";

export interface RegisterResult {
  agent_id: number;
  agent_name: string;
  topic_id: number;
  topic_name: string;
  inbox_creative_id: number;
  ws_url: string;
}

export class CollavreClient {
  private baseUrl: string;
  private token: string;

  constructor(config: CollavreConfig) {
    this.baseUrl = config.url.replace(/\/$/, "");
    this.token = config.token;
  }

  async register(name: string): Promise<RegisterResult> {
    const res = await fetch(`${this.baseUrl}/api/v1/agent/register`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify({ name }),
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
  // (pending_tool_call) so the human's subsequent allow/deny is relayed
  // straight to this suspended session instead of deadlocking behind the
  // delegated topic slot.
  async notify(
    topicId: number,
    text: string,
    taskId?: number,
    permissionRequestId?: string,
  ): Promise<{ comment_id: number }> {
    const body: Record<string, unknown> = { topic_id: topicId, text };
    if (taskId !== undefined && taskId !== null) {
      body.task_id = taskId;
    }
    if (permissionRequestId !== undefined && permissionRequestId !== null) {
      body.permission_request_id = permissionRequestId;
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

  async unregister(agentId: number, topicId?: number): Promise<void> {
    const url = new URL(`${this.baseUrl}/api/v1/agent/${agentId}`);
    if (topicId !== undefined) {
      url.searchParams.set("topic_id", String(topicId));
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
