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
// claim.
//
// A pending permission has NO wall-clock timeout: the approver may click the
// channel's approve/deny buttons seconds or hours after the prompt is surfaced
// (the whole point of remote approval is that the human can be away). Expiring
// by time would silently drop a valid late decision — the server has already
// persisted action_executed_at and hidden the buttons, so the suspended turn
// would hang with no retry path. We therefore keep entries until claimed, and
// bound memory by capacity (FIFO eviction of the oldest, presumably abandoned,
// entries) rather than by age.
export class PermissionCoordinator {
  // Insertion-ordered set of pending request_ids. Map/Set iteration order is
  // insertion order, so the first entry is always the oldest.
  private pending = new Set<string>();
  private readonly maxEntries: number;

  constructor(maxEntries = 1024) {
    this.maxEntries = maxEntries;
  }

  add(requestId: string): void {
    // Re-insert so a re-surfaced id moves to the newest position.
    this.pending.delete(requestId);
    this.pending.add(requestId);
    // Bound memory: evict the oldest entries beyond the cap. These are prompts
    // abandoned without a decision (e.g. the turn was cancelled); a genuinely
    // pending prompt is never evicted in practice because a single session
    // raises far fewer than maxEntries concurrent prompts.
    while (this.pending.size > this.maxEntries) {
      const oldest = this.pending.values().next().value as string;
      this.pending.delete(oldest);
    }
  }

  // Consume a pending request by id. Returns true only if THIS session surfaced
  // it — the caller then forwards the decision to Claude Code. false means the
  // decision belongs to a sibling session (which never surfaced this id).
  claim(requestId: string): boolean {
    return this.pending.delete(requestId);
  }

  hasPending(requestId: string): boolean {
    return this.pending.has(requestId);
  }

  // The request_ids this session still holds pending, in insertion order. Sent
  // after every (re)subscribe (pull-on-resubscribe) so the server re-broadcasts
  // the recorded decision for exactly these — redelivering a decision that was
  // broadcast into a subscriber-less stream during a WebSocket reconnect gap.
  // Because this set is the source of truth for what still needs delivery, the
  // redelivery is bounded by the plugin's own outstanding prompts rather than a
  // wall-clock window: an outage of any length is covered, and a decision
  // already claimed (or cleared on turn end) is simply never requested again.
  pendingIds(): string[] {
    return [...this.pending];
  }

  // Drop every pending request. Called when the dispatched turn ends (the reply
  // tool fires): any request still pending was resolved by the local TUI dialog
  // (or abandoned), since Claude Code sends no per-request resolution signal and
  // a turn reaching reply has already settled every tool prompt. Clearing stops
  // a later click on the now-stale Collavre approval comment from being claimed
  // and forwarded to a turn that is already over, and frees the ids so they
  // cannot collide with a future prompt.
  clear(): void {
    this.pending.clear();
  }
}
