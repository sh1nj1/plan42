# frozen_string_literal: true

require "test_helper"

class ApprovalGateCommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @existing_creative_ids = Collavre::Creative.ids
    @user = users(:one)
    @agent = users(:ai_bot)
    @creative = Collavre::Creative.create!(user: @user, description: "Approval commit boundary")
    @task = Collavre::Task.create!(name: "Approval", status: "pending_approval", agent: @agent,
      creative: @creative, topic_id: @creative.main_topic.id,
      pending_tool_call: { kind: "approval_gate", tool_call_id: "gate-commit" })
    @comment = Collavre::Comment.create!(creative: @creative, topic_id: @task.topic_id,
      user: @agent, approver: @user, content: "Proceed?",
      action: { action: "approval_gate", task_id: @task.id, tool_call_id: "gate-commit" }.to_json)
    clear_enqueued_jobs
  end

  teardown do
    Collavre::Task.where(creative: @creative).destroy_all if @creative
    @creative&.topics&.destroy_all
    @creative&.destroy!
    Collavre::Creative.where.not(id: @existing_creative_ids).destroy_all if @existing_creative_ids
    ActiveJob::Base.queue_adapter = @old_adapter
  end

  %w[approved denied].each do |decision|
    test "#{decision} enqueues resume only after the outer transaction commits" do
      observed = []
      adapter = Collavre::ApprovalGateResumeJob.queue_adapter
      original_enqueue = adapter.method(:enqueue)
      adapter.stub(:enqueue, lambda { |job|
        if job.is_a?(Collavre::ApprovalGateResumeJob)
          assert_not Collavre::Task.connection.transaction_open?
          observed << Collavre::Task.find(@task.id).pending_tool_call.dig("decision", "decision")
        end
        original_enqueue.call(job)
      }) do
        assert_enqueued_with(job: Collavre::ApprovalGateResumeJob, args: [ @task.id, "gate-commit" ]) do
          Collavre::Task.transaction do
            Collavre::Comments::ApprovalGateDecision.new(@comment, @user).call(decision)
            assert_no_enqueued_jobs(only: Collavre::ApprovalGateResumeJob)
            assert_empty observed
          end
        end
      end
      assert_equal [ decision ], observed
    end
  end

  test "rollback discards both the decision and the deferred resume" do
    assert_no_enqueued_jobs(only: Collavre::ApprovalGateResumeJob) do
      Collavre::Task.transaction do
        Collavre::Comments::ApprovalGateDecision.new(@comment, @user).call("approved")
        raise ActiveRecord::Rollback
      end
    end
    assert_nil @task.reload.pending_tool_call["decision"]
    assert_nil @comment.reload.action_executed_at
  end
end
