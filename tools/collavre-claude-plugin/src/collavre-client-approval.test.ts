import { test } from "node:test";
import assert from "node:assert/strict";
import { CollavreClient, ApprovalRelayRejectedError } from "../dist/collavre-client.js";

const client = () => new CollavreClient({ url: "https://collavre.test", token: "test", agentName: "test" });
const request = { topicId: 42, requestId: "approval-1", question: "Proceed?" };

test("approval relay forwards correlation, approver and abort signal", async t => {
  const controller = new AbortController();
  t.mock.method(globalThis, "fetch", async (_url: unknown, options: RequestInit) => {
    assert.equal(options.signal, controller.signal);
    assert.deepEqual(JSON.parse(options.body as string), {
      topic_id: 42, text: "", permission_request_id: "approval-1", approval_question: "Proceed?",
      task_id: 7, approver_user_id: 9,
    });
    return new Response(JSON.stringify({ comment_id: 17 }), { status: 201 });
  });
  assert.deepEqual(await client().requestApproval({ ...request, taskId: 7, approverUserId: 9, signal: controller.signal }), { comment_id: 17 });
});

test("only explicit validation and authentication failures prove the request was rejected", async t => {
  for (const status of [400, 401, 403, 404, 422, 500, 502]) {
    const mock = t.mock.method(globalThis, "fetch", async () => new Response("failure", { status }));
    await assert.rejects(client().requestApproval(request), error => {
      assert.ok(error instanceof Error);
      assert.equal(error instanceof ApprovalRelayRejectedError, status < 500);
      return true;
    });
    mock.mock.restore();
  }
});

test("an unreadable success response is ambiguous because the comment may already exist", async t => {
  t.mock.method(globalThis, "fetch", async () => new Response("truncated JSON", { status: 201 }));
  await assert.rejects(client().requestApproval(request), error => {
    assert.ok(error instanceof Error);
    assert.equal(error instanceof ApprovalRelayRejectedError, false);
    return true;
  });
});
