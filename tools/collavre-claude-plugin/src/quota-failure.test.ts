import test from "node:test";
import assert from "node:assert/strict";
import { quotaFailure } from "./quota-failure.ts";

const base = { hook_event_name: "StopFailure", error: "rate_limit" };
test("session quota with unambiguous reset is forwarded as seconds", () => {
  assert.deepEqual(quotaFailure({ ...base, error_details: "Usage limit resets 2026-09-22T09:00:00Z" }, Date.parse("2026-09-22T08:00:00Z")), { retry_after: "3600" });
});
test("ordinary rate limits and permanent errors do not suspend", () => {
  for (const input of [{}, { ...base, error_details: "429 Too Many Requests" }, { ...base, error: "billing_error", error_details: "usage limit" }, { ...base, error_details: "Usage limit: check billing" }]) {
    assert.equal(quotaFailure(input), null);
  }
});
test("unknown timezone, past and unreasonable reset use bounded server probes", () => {
  for (const error_details of ["You've hit your limit · resets 5pm", "session limit", "Usage limit resets 2020-01-01T00:00:00Z", "Usage limit resets 2099-01-01T00:00:00Z"]) {
    assert.deepEqual(quotaFailure({ ...base, error_details }), {});
  }
});

test("request throttling with a reset is not a subscription cap", () => {
  for (const error_details of ["Rate limit resets 2026-09-22T09:00:00Z", "You've hit your limit: requests per minute", "Usage limit: rate_limit_exceeded", "Usage limit: account deactivated"]) {
    assert.equal(quotaFailure({ ...base, error_details }), null);
  }
});
