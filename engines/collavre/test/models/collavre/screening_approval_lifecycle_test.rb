# frozen_string_literal: true

require "test_helper"

module Collavre
  # A screening pause uses the approval-gate surface, so the gate's lifecycle
  # rules apply to it too.
  class ScreeningApprovalLifecycleTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @creative = Creative.create!(description: "Gate lifecycle", user: @owner)
      @topic = @creative.topics.create!(name: "Gate", user: @owner)
      @agent = users(:ai_bot)
      @task = Task.create!(name: "Screened", agent: @agent, creative: @creative, topic_id: @topic.id,
        status: "pending_approval",
        pending_tool_call: { kind: Screening::PENDING_KIND, tool_call_id: "screening-1", approver_id: @owner.id })
    end

    test "screening is an approval-gate kind" do
      assert Task.approval_gate_kind?(@task.pending_tool_call)
      assert Task.approval_gate_kind?({ "kind" => "approval_gate" })
      assert_not Task.approval_gate_kind?({ "kind" => "other" })
      assert_not Task.approval_gate_kind?(nil)
    end

    test "deleting the undecided gate comment cancels the paused turn" do
      gate = @creative.comments.create!(topic_id: @topic.id, user: @agent, approver: @owner, content: "Deliver?",
        skip_dispatch: true, action: { action: "approval_gate", task_id: @task.id, tool_call_id: "screening-1" }.to_json)
      gate.destroy!
      assert @task.reload.cancelled?
      assert_nil @task.pending_tool_call
    end

    test "a terminal status clears the screening pause" do
      @task.update!(status: "failed")
      assert_nil @task.reload.pending_tool_call
    end
  end
end
