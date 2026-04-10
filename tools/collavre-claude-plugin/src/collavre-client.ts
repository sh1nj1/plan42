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

  async reply(topicId: number, text: string): Promise<{ comment_id: number }> {
    const res = await fetch(`${this.baseUrl}/api/v1/agent/reply`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify({ topic_id: topicId, text }),
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(`Reply failed (${res.status}): ${body}`);
    }

    return res.json() as Promise<{ comment_id: number }>;
  }

  async unregister(agentId: number): Promise<void> {
    await fetch(`${this.baseUrl}/api/v1/agent/${agentId}`, {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${this.token}`,
      },
    }).catch(() => {
      // Best-effort cleanup on shutdown
    });
  }
}
