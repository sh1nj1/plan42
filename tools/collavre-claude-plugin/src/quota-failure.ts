export interface FailureInput {
  hook_event_name?: string;
  error?: string;
  error_details?: string;
  last_assistant_message?: string;
  cwd?: string;
}

// A requests/minute error is not a session cap. Unqualified local reset times
// use bounded server backoff; guessing the date or timezone risks retry loops.
export function quotaFailure(input: FailureInput, now = Date.now()): { retry_after?: string } | null {
  if (input.hook_event_name !== "StopFailure" || input.error !== "rate_limit") return null;
  const message = `${input.error_details ?? ""} ${input.last_assistant_message ?? ""}`;
  if (/billing|credit balance|payment|account (disabled|deactivated|on hold)/i.test(message)) return null;
  if (/rate_limit_exceeded|(?:requests?|tokens?)[ /-]+per[ /-]+minute|\b[rt]pm\b|request rate limit/i.test(message)) return null;
  if (!/usage limit|session limit|insufficient_quota|you(?:’|')?ve hit your limit/i.test(message)) return null;
  const stamp = message.match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})/);
  const delay = stamp ? Math.ceil((Date.parse(stamp[0]) - now) / 1000) : NaN;
  return Number.isFinite(delay) && delay > 0 && delay <= 14 * 86400 ? { retry_after: String(delay) } : {};
}
