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

// The server's machine-readable marker for the ONE benign reply conflict: the
// delegated task was already completed, so the dispatch this reply answers has
// an answer. See TaskClaimService::CONFLICT_ALREADY_COMPLETED.
const BENIGN_REPLY_CONFLICT_REASON = "already_completed";

/**
 * Whether a 409 body from /agent/reply is the sibling-session dedup and may be
 * suppressed. Anything else — a cancelled/failed/recovered task, an id that is
 * not ours, an unparseable body, or an older server that sends no reason at all
 * — is NOT: the reply in hand is the only copy of that answer, and suppressing
 * it drops it with no trace. Unmarked conflicts therefore fall back to being
 * raised, which is what this client did before dedup existed.
 */
export function isBenignReplyDedup(body: string): boolean {
  try {
    const parsed = JSON.parse(body) as { reason?: unknown };
    return parsed?.reason === BENIGN_REPLY_CONFLICT_REASON;
  } catch {
    return false;
  }
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
  ): Promise<{ handled: true; comment_id: number } | { handled: false; reason: string }> {
    const body: Record<string, unknown> = { topic_id: topicId, text, task_id: taskId };

    const res = await fetch(`${this.baseUrl}/api/v1/agent/reply`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify(body),
    });

    // 409 Conflict has two causes and only one of them is benign.
    //
    // Benign: multiple Claude Code sessions in the SAME working directory share
    // one Collavre agent; a work-topic dispatch fans out to all of them and each
    // session's turn calls reply with the same task_id. The server's atomic task
    // claim lets exactly one win — the others are refused. The message was
    // already delivered by a sibling, so this is success-with-nothing-to-do.
    //
    // Not benign: the dispatch left `delegated` WITHOUT being answered — an
    // offline session cancelled it, it failed, or stuck-task recovery flipped it
    // while this turn was still composing. The claim fails the same way, but no
    // sibling posted anything, so treating it as dedup drops the user's answer
    // silently. Only the server's explicit already_completed marker suppresses.
    if (res.status === 409) {
      const respBody = await res.text();
      if (!isBenignReplyDedup(respBody)) {
        throw new Error(`Reply failed (409): ${respBody}`);
      }
      return { handled: false, reason: respBody };
    }

    if (!res.ok) {
      const respBody = await res.text();
      throw new Error(`Reply failed (${res.status}): ${respBody}`);
    }

    const json = (await res.json()) as { comment_id: number };
    return { handled: true, comment_id: json.comment_id };
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
