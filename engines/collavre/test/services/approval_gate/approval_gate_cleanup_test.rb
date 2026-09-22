# frozen_string_literal: true

require "test_helper"

class ApprovalGateCleanupTest < ActiveSupport::TestCase
  setup do
    @payload = { "kind" => "approval_gate", "tool_call_id" => "gate-1",
      "decision" => { "decision" => "approved" },
      "messages" => [ { "role" => "user", "content" => "data:image/png;base64,private" } ] }
    @task = Collavre::Task.create!(name: "Gate cleanup", agent: users(:ai_bot),
      status: "pending_approval", pending_tool_call: @payload)
  end

  %w[done failed cancelled escalated].each do |status|
    test "#{status} clears the conversation and decision" do
      @task.update!(status: "running")
      assert_equal @payload, @task.reload.pending_tool_call
      @task.update!(status: status)
      assert_nil @task.reload.pending_tool_call
    end
  end

  test "active states preserve recovery data including a subsequent gate" do
    %w[pending queued running delegated pending_approval].each do |status|
      @task.update!(status: status)
      assert_equal @payload, @task.reload.pending_tool_call
    end
    next_gate = @payload.except("decision").merge("tool_call_id" => "gate-2")
    @task.update!(pending_tool_call: next_gate)
    assert_equal next_gate, @task.reload.pending_tool_call
  end

  test "rolling back completion preserves the snapshot for recovery" do
    Collavre::Task.transaction do
      @task.update!(status: "done")
      assert_nil @task.pending_tool_call
      raise ActiveRecord::Rollback
    end
    assert_equal "pending_approval", @task.reload.status
    assert_equal @payload, @task.pending_tool_call
  end

  test "ordinary tool approval payloads are unchanged" do
    payload = { "tool_name" => "other_tool" }
    @task.update!(pending_tool_call: payload, status: "done")
    assert_equal payload, @task.reload.pending_tool_call
    @task.update!(pending_tool_call: nil)
    assert_nil @task.reload.pending_tool_call
  end
end
