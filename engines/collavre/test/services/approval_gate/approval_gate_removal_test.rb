# frozen_string_literal: true

require "test_helper"

class ApprovalGateRemovalTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @agent = users(:ai_bot)
    @creative = Collavre::Creative.create!(user: @user, description: "Approval removal")
    @task = Collavre::Task.create!(name: "Approval", status: "pending_approval", agent: @agent,
      creative: @creative, topic_id: @creative.main_topic.id,
      pending_tool_call: { kind: "approval_gate", tool_call_id: "gate-rm", messages: [ { role: "user" } ] })
    @comment = gate_comment
  end

  test "deleting an undecided gate cancels the task and frees its slot" do
    released, dequeued = track_cleanup { @comment.destroy! }

    @task.reload
    assert_equal "cancelled", @task.status
    assert_nil @task.pending_tool_call
    assert_equal [ @task.id ], released
    assert_equal [ [ @task.topic_id, @creative.id ] ], dequeued
  end

  test "moving an undecided gate out of its topic cancels the task" do
    other = Collavre::Topic.create!(creative: @creative, name: "elsewhere", user: @user)
    track_cleanup { @comment.update!(topic_id: other.id) }

    assert_equal "cancelled", @task.reload.status
  end

  test "deleting a decided gate leaves the resuming task alone" do
    @task.update!(pending_tool_call: @task.pending_tool_call.merge("decision" => { "decision" => "approved" }))
    released, = track_cleanup { @comment.destroy! }

    assert_equal "pending_approval", @task.reload.status
    assert_empty released
  end

  test "deleting a gate for a superseded call leaves the task alone" do
    @task.update!(pending_tool_call: @task.pending_tool_call.merge("tool_call_id" => "gate-newer"))
    track_cleanup { @comment.destroy! }

    assert_equal "pending_approval", @task.reload.status
  end

  test "a gate whose task belongs to another agent is ignored" do
    @task.update!(agent: users(:two))
    track_cleanup { @comment.destroy! }

    assert_equal "pending_approval", @task.reload.status
  end

  test "a gate whose task is gone is ignored" do
    Collavre::Task.where(id: @task.id).delete_all
    released, = track_cleanup { @comment.destroy! }

    assert_empty released
  end

  test "ordinary comment edits do not touch the gate task" do
    track_cleanup { @comment.update!(content: "Proceed now?") }

    assert_equal "pending_approval", @task.reload.status
  end

  private

  def gate_comment
    Collavre::Comment.create!(creative: @creative, topic_id: @task.topic_id,
      user: @agent, approver: @user, content: "Proceed?",
      action: { action: "approval_gate", task_id: @task.id, tool_call_id: "gate-rm" }.to_json)
  end

  def track_cleanup(&block)
    released = []
    dequeued = []
    tracker = Object.new
    tracker.define_singleton_method(:release!) { |id, **| released << id }
    Collavre::Orchestration::ResourceTracker.stub(:for, tracker) do
      Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(*args) { dequeued << args }, &block)
    end
    [ released, dequeued ]
  end
end
