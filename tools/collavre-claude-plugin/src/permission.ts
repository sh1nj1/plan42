// Native Claude Channel permission relay (CC v2.1.168+, gated by the
// `tengu_harbor_permissions` GrowthBook flag). When Claude Code needs tool
// permission mid-turn it relays the prompt to every channel server that
// declares both `claude/channel` and `claude/channel/permission` capabilities,
// IN ADDITION to the local TUI dialog (first responder wins).
//
// The prompt is surfaced as a STRUCTURED approval comment: the server renders
// the (localized) text and attaches approve/deny buttons. The human's click
// relays an explicit { request_id, behavior } decision back over the agent
// stream — there is no free-text allow/deny parsing. This module owns the
// plugin's side: tracking which prompts this session raised so it only acts on
// decisions for its own requests.

export type Behavior = "allow" | "deny";

export interface PermissionRequest {
  request_id: string;
  tool_name?: string;
  description?: string;
  input_preview?: unknown;
}

// Tracks the permission requests THIS session surfaced into Collavre, so an
// incoming decision — delivered over the shared per-agent stream that sibling
// sessions also hear — is acted on only by the session that actually raised it.
// A decision is correlated by request_id, unique to the Claude Code process
// that issued the prompt; a sibling that never surfaced it has nothing to
// claim. Entries expire after a TTL so a prompt abandoned without a decision
// (e.g. the turn was cancelled) does not leak.
export class PermissionCoordinator {
  private pending = new Map<string, number>(); // request_id -> createdAt
  private readonly ttlMs: number;
  private readonly now: () => number;

  constructor(ttlMs = 5 * 60_000, now: () => number = () => Date.now()) {
    this.ttlMs = ttlMs;
    this.now = now;
  }

  add(requestId: string): void {
    this.pending.set(requestId, this.now());
  }

  // Consume a pending request by id. Returns true only if THIS session surfaced
  // it (and it has not expired) — the caller then forwards the decision to
  // Claude Code. false means the decision belongs to a sibling session or the
  // request has aged out.
  claim(requestId: string): boolean {
    this.prune();
    return this.pending.delete(requestId);
  }

  hasPending(requestId: string): boolean {
    this.prune();
    return this.pending.has(requestId);
  }

  private prune(): void {
    const cutoff = this.now() - this.ttlMs;
    for (const [id, createdAt] of this.pending) {
      if (createdAt < cutoff) this.pending.delete(id);
    }
  }
}
