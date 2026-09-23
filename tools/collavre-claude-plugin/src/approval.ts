// Agent-initiated approval requests (the Claude Channel counterpart of the
// native `approval_request` gate).
//
// A native Collavre agent parks its whole turn on an approval gate: the server
// stores the in-flight LLM conversation and replays it with the decision spliced
// in as the blocked tool call's result. A Claude Code session's conversation
// lives inside the Claude Code process, so it cannot be stored and replayed.
// What CAN be blocked is the tool call itself — exactly what the native
// tool-permission relay already does — so an approval request rides the same
// rail: surface a structured approval comment, then hold the MCP tool call open
// until the human clicks approve/deny and the decision arrives over the agent
// stream. The model sees a normal tool result carrying the decision, with no
// context lost.
//
// This module owns the plugin's side of that wait: which request_ids this
// session raised as approval requests (as opposed to relayed tool prompts,
// which must be forwarded to Claude Code instead) and the promise each blocked
// tool call is parked on.

import type { Behavior } from "./permission.js";

export interface ApprovalDecision {
  behavior: Behavior;
  reason?: string;
  decided_by?: number;
  decided_by_name?: string;
}

interface Entry {
  // Set while a tool call is actively parked on this request.
  resolve?: (decision: ApprovalDecision | null) => void;
  // Set when the decision arrived with no tool call parked on it (the wait
  // window elapsed and the model has not re-awaited yet). Held so the re-await
  // returns immediately instead of hanging on a decision already broadcast.
  decision?: ApprovalDecision;
}

// Tracks this session's outstanding approval requests.
//
// Like PermissionCoordinator there is NO wall-clock expiry: the approver may
// take hours, and dropping an entry by age would strand the request on a
// decision that can never be delivered again (the server has already recorded
// it and hidden the buttons). Memory is bounded by capacity instead, evicting
// the oldest — presumably abandoned — entries.
export class ApprovalWaiter {
  private entries = new Map<string, Entry>();
  private readonly maxEntries: number;

  constructor(maxEntries = 256) {
    this.maxEntries = maxEntries;
  }

  // Start tracking a request before it is relayed to the server, so a decision
  // that races the notify response still finds an entry to settle.
  open(requestId: string): void {
    this.entries.delete(requestId);
    this.entries.set(requestId, {});
    while (this.entries.size > this.maxEntries) {
      const oldest = this.entries.keys().next().value as string;
      this.resolveEntry(oldest, null);
      this.entries.delete(oldest);
    }
  }

  // True when this id is one of THIS session's approval requests. The decision
  // handler checks this first: an approval decision resolves a parked tool call,
  // whereas a relayed tool-permission decision must be forwarded to Claude Code.
  has(requestId: string): boolean {
    return this.entries.has(requestId);
  }

  // Park until the decision arrives, or until timeoutMs elapses.
  //
  // Returns null on timeout (or for an unknown id) WITHOUT dropping the entry:
  // the tool then reports "still pending" and the model can re-await the same
  // request_id. A decision arriving in that gap is cached and returned by the
  // next wait, so the window is a client-timeout guard, not a deadline on the
  // human.
  async wait(requestId: string, timeoutMs: number): Promise<ApprovalDecision | null> {
    const entry = this.entries.get(requestId);
    if (!entry) return null;
    if (entry.decision) {
      this.entries.delete(requestId);
      return entry.decision;
    }
    return new Promise<ApprovalDecision | null>(resolve => {
      const timer = setTimeout(() => {
        entry.resolve = undefined;
        resolve(null);
      }, timeoutMs);
      entry.resolve = decision => {
        clearTimeout(timer);
        resolve(decision);
      };
    });
  }

  // Deliver a decision. Returns false for an id this session never raised as an
  // approval request (a sibling session's, or a relayed tool prompt) so the
  // caller can fall through to the tool-permission path.
  settle(requestId: string, decision: ApprovalDecision): boolean {
    const entry = this.entries.get(requestId);
    if (!entry) return false;

    if (entry.resolve) {
      this.entries.delete(requestId);
      this.resolveEntry(requestId, decision, entry);
    } else {
      entry.decision = decision;
    }
    return true;
  }

  // The requests this session still holds open, in insertion order. Used to
  // refuse raising a SECOND request while one is undecided: the only way to get
  // there is a wait window elapsing and the model asking afresh instead of
  // re-awaiting, which would leave a duplicate gate in the topic that nobody
  // needs to answer.
  openIds(): string[] {
    return [...this.entries.keys()];
  }

  // Stop tracking a rejected relay or an explicitly abandoned local wait, so
  // it does not block the next one as an "open" request.
  cancel(requestId: string): void {
    this.resolveEntry(requestId, null);
    this.entries.delete(requestId);
  }

  // Drop every tracked request. Called when the dispatched turn ends (the reply
  // tool fires): a decision clicked afterwards belongs to a turn that is over,
  // and any still-parked call would never be answered. Parked callers are
  // released with null so they report "pending" rather than hanging forever.
  clear(): void {
    for (const requestId of [...this.entries.keys()]) {
      this.resolveEntry(requestId, null);
    }
    this.entries.clear();
  }

  private resolveEntry(requestId: string, decision: ApprovalDecision | null, known?: Entry): void {
    const entry = known ?? this.entries.get(requestId);
    const resolve = entry?.resolve;
    if (!entry || !resolve) return;

    entry.resolve = undefined;
    resolve(decision);
  }
}

// Default wait window for one blocked approval_request call. This is NOT a
// deadline on the human: it bounds how long a single MCP tool call stays open
// (Claude Code cancels a call that outlives its own tool timeout) and the model
// re-awaits the same request_id afterwards.
const DEFAULT_WAIT_MS = 60_000;
const MIN_WAIT_MS = 1;
const MAX_WAIT_MS = 3_600_000;

function numericEnv(value: string | undefined): number | null {
  if (value === undefined || value.trim() === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

export function resolveApprovalWaitMs(env: Record<string, string | undefined>): number {
  const clamp = (ms: number) => Math.min(MAX_WAIT_MS, Math.max(MIN_WAIT_MS, ms));

  // Claude Code aborts an MCP tool call that outruns MCP_TOOL_TIMEOUT. Return
  // "still pending" a little before that so the model gets an actionable result
  // (with the request_id to re-await) instead of a cancelled tool call.
  const clientTimeout = numericEnv(env.MCP_TOOL_TIMEOUT);
  if (clientTimeout) return clamp(Math.floor(clientTimeout * 0.8));

  return DEFAULT_WAIT_MS;
}

export function newApprovalRequestId(uuid: () => string): string {
  return `approval-${uuid()}`;
}

// The decision as the model sees it. Denial is a normal outcome, so it is spelled
// out as an instruction rather than an error: the model must not retry the denied
// action (the native gate's tool description carries the same rule).
export function formatApprovalDecision(decision: ApprovalDecision): string {
  const lines: string[] =
    decision.behavior === "allow"
      ? ["approved — the human approved your request; proceed."]
      : [
          "denied — the human denied your request. Do not perform the denied action; " +
            "reconsider the plan and report what you will do instead.",
        ];

  const who = [decision.decided_by_name, decision.decided_by ? `#${decision.decided_by}` : null]
    .filter(Boolean)
    .join(" ");
  if (who) lines.push(`decided_by: ${who}`);
  if (decision.reason) lines.push(`reason: ${decision.reason}`);
  return lines.join("\n");
}

export function formatApprovalPending(requestId: string, waitMs: number): string {
  return [
    `pending — nobody has decided yet (waited ${Math.round(waitMs / 1000)}s). The request stays open in Collavre.`,
    `To keep waiting, call approval_request again with request_id="${requestId}" (no question needed).`,
    `If you confirmed the gate was deleted, call approval_request with request_id="${requestId}" and abandon=true to release local tracking. This is not approval.`,
    "To stop waiting, end your turn and tell the human you are blocked on their decision.",
  ].join("\n");
}

// A re-await naming a request this session never raised (or one already
// consumed / cleared at turn end). Distinguished from "pending" so the model
// stops re-calling instead of looping on an id that can never resolve.
export function formatApprovalUnknown(requestId: string): string {
  return (
    `No open approval request with request_id="${requestId}" in this session. ` +
    "It was already decided and reported, abandoned locally, or its turn ended. This is not approval. " +
    "Ask again with a question to raise a new request."
  );
}
