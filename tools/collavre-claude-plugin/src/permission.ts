// Native Claude Channel permission relay (CC v2.1.168+, gated by the
// `tengu_harbor_permissions` GrowthBook flag). When Claude Code needs tool
// permission mid-turn it relays the prompt to every channel server that
// declares both `claude/channel` and `claude/channel/permission` capabilities,
// IN ADDITION to the local TUI dialog (first responder wins). This module owns
// the plugin's side: turning a topic reply into an allow/deny decision and
// correlating it back to the request that is awaiting an answer.

export type Behavior = "allow" | "deny";

export interface PermissionRequest {
  request_id: string;
  tool_name?: string;
  description?: string;
  input_preview?: unknown;
}

// Strict, whole-message matching. The prompt explicitly tells the user to reply
// "allow" or "deny", so we only treat an unambiguous one-word answer as a
// decision — anything else is a normal message and must be forwarded to Claude
// (e.g. "no idea what that does" must NOT deny).
const ALLOW_WORDS = new Set([
  "allow", "yes", "y", "approve", "ok", "okay", "허용", "승인", "네", "예",
]);
const DENY_WORDS = new Set([
  "deny", "no", "n", "reject", "cancel", "거부", "불허", "취소", "아니", "아니오",
]);

export function parseDecision(text: string): Behavior | null {
  const t = text.trim().toLowerCase();
  if (ALLOW_WORDS.has(t)) return "allow";
  if (DENY_WORDS.has(t)) return "deny";
  return null;
}

interface Pending {
  request_id: string;
  createdAt: number;
}

// Correlates incoming permission requests to the topic whose turn triggered
// them, then maps the user's topic reply back to a decision. Keyed by topic_id:
// the permission_request payload carries no topic, so index.ts records the
// active dispatch's topic and we resolve against that. Multiple pending
// requests on one topic (sequential tool prompts in a single turn) resolve
// FIFO.
export class PermissionCoordinator {
  private byTopic = new Map<number, Pending[]>();
  private readonly ttlMs: number;
  private readonly now: () => number;

  constructor(ttlMs = 5 * 60_000, now: () => number = () => Date.now()) {
    this.ttlMs = ttlMs;
    this.now = now;
  }

  add(topicId: number, requestId: string): void {
    const list = this.byTopic.get(topicId) ?? [];
    list.push({ request_id: requestId, createdAt: this.now() });
    this.byTopic.set(topicId, list);
  }

  // If a live permission request is pending for this topic AND the reply parses
  // to allow/deny, consume the oldest one and return the decision. Otherwise
  // null — the caller forwards the comment to Claude as a normal message.
  tryResolve(
    topicId: number,
    text: string,
  ): { request_id: string; behavior: Behavior } | null {
    this.prune(topicId);
    const list = this.byTopic.get(topicId);
    if (!list || list.length === 0) return null;
    const behavior = parseDecision(text);
    if (!behavior) return null;
    const pending = list.shift()!;
    if (list.length === 0) this.byTopic.delete(topicId);
    return { request_id: pending.request_id, behavior };
  }

  hasPending(topicId: number): boolean {
    this.prune(topicId);
    return (this.byTopic.get(topicId)?.length ?? 0) > 0;
  }

  private prune(topicId: number): void {
    const list = this.byTopic.get(topicId);
    if (!list) return;
    const cutoff = this.now() - this.ttlMs;
    const live = list.filter((p) => p.createdAt >= cutoff);
    if (live.length === 0) this.byTopic.delete(topicId);
    else this.byTopic.set(topicId, live);
  }
}

// Human-readable prompt posted into the topic so the user can see what is
// awaiting approval and reply allow/deny.
export function formatPermissionPrompt(req: PermissionRequest): string {
  const lines = [`🔐 권한 요청: **${req.tool_name ?? "tool"}**`];
  if (req.description) lines.push(req.description);
  const preview = renderPreview(req.input_preview);
  if (preview) lines.push("```\n" + preview + "\n```");
  lines.push("승인하려면 `allow`, 거부하려면 `deny` 로 답해주세요.");
  return lines.join("\n");
}

function renderPreview(input: unknown): string | null {
  if (input == null) return null;
  if (typeof input === "string") return input.slice(0, 2000);
  try {
    return JSON.stringify(input, null, 2).slice(0, 2000);
  } catch {
    return null;
  }
}
