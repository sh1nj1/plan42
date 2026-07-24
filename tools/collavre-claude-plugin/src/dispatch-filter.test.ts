import { test } from "node:test";
import assert from "node:assert/strict";
import { shouldHandleDispatch } from "./dispatch-filter.ts";

test("owns a dispatch on its own session topic", () => {
  assert.equal(
    shouldHandleDispatch({ sessionTopic: true, dispatchTopicId: 10, mySessionTopicId: 10 }),
    true,
  );
});

test("ignores a dispatch on a SIBLING session's topic", () => {
  // Shared agent → both sessions hear agent:user:<id>; only the owner answers.
  assert.equal(
    shouldHandleDispatch({ sessionTopic: true, dispatchTopicId: 99, mySessionTopicId: 10 }),
    false,
  );
});

test("handles a work/project topic dispatch regardless of id (atomic claim dedups)", () => {
  assert.equal(
    shouldHandleDispatch({ sessionTopic: false, dispatchTopicId: 77, mySessionTopicId: 10 }),
    true,
  );
});

test("back-compat: a legacy server that omits the flag is handled (single-session)", () => {
  assert.equal(
    shouldHandleDispatch({ sessionTopic: undefined, dispatchTopicId: 77, mySessionTopicId: 10 }),
    true,
  );
});
