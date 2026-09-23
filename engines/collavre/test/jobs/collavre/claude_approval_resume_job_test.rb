# frozen_string_literal: true

require "test_helper"

module Collavre
  class ClaudeApprovalResumeJobTest < ActiveSupport::TestCase
    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      @user = users(:one)
      @creative = Creative.create!(description: "Approval work", user: @user)
      @agent = User.create!(email: "resume@agent.collavre.local", name: "Resume Claude",
                            password: "password", llm_vendor: "anthropic",
                            llm_model: "claude-code", created_by_id: @user.id)
      CreativeShare.create!(creative: @creative, user: @agent, permission: "feedback")
      @topic = @creative.topics.create!(name: "Work", user: @user)
      @topic.set_primary_agent!(@agent)
      @origin = Task.create!(name: "Original", agent: @agent, creative: @creative,
                             topic_id: @topic.id, status: "done", trigger_event_payload: {})
      @approval = @creative.comments.create!(
        topic: @topic, user: @agent, approver: @user, content: "Deploy?",
        skip_default_user: true, skip_dispatch: true,
        action: JSON.generate(action: "claude_channel_permission", kind: "approval_request",
                              request_id: "approval-1", question: "Deploy?", origin_task_id: @origin.id)
      )
      ActiveJob::Base.queue_adapter = :test
    end

    teardown do
      ActiveJob::Base.queue_adapter = @previous_adapter
    end

    test "reply before decision preserves request and decision makes one new task and chat" do
      ClaudeApprovalHandoff.finish!(@origin, [ "approval-1" ])
      assert JSON.parse(@approval.reload.action)["turn_finished"]
      assert_no_difference("Task.count") { ClaudeApprovalResumeJob.perform_now(@approval.id) }
      decide
      assert_difference("Task.count", 1) do
        assert_difference("Comment.count", 1) { resume }
      end
      task = continuation
      assert_equal "pending", task.status
      assert_equal @agent.id, task.agent_id
      assert_equal @topic.id, task.topic_id
      assert_includes task.trigger_event_payload.dig("comment", "content"), "Deploy?"
      assert_includes task.trigger_event_payload.dig("comment", "content"), "revise"
      assert_no_difference("Task.count") { 2.times { resume } }
    end

    test "decision immediately before reply is handed off exactly once" do
      decide
      assert_no_difference("Task.count") { resume }
      ClaudeApprovalHandoff.finish!(@origin, [ "approval-1" ])
      resume
      assert_equal 1, Task.where(trigger_event_name: "claude_channel_approval").count
    end

    test "consumed decision omitted from reply does not resume" do
      decide
      ClaudeApprovalHandoff.finish!(@origin, [])
      assert_no_difference("Task.count") { resume }
    end

    test "foreign task cannot hand off request" do
      other = Task.create!(name: "Other", agent: @agent, creative: @creative, topic_id: @topic.id, status: "done")
      ClaudeApprovalHandoff.finish!(other, [ "approval-1" ])
      refute JSON.parse(@approval.reload.action)["turn_finished"]
    end

    test "reconnect recovers persisted decision and lost enqueue without a duplicate task" do
      handoff_and_decide
      ClaudeApprovalResumeJob.perform_now(nil, @agent.id)
      first_id = continuation.id
      assert_no_difference("Task.count") { ClaudeApprovalResumeJob.perform_now(nil, @agent.id) }
      assert_equal first_id, continuation.id
    end

    test "busy topic queues continuation and coalescing preserves both turns" do
      busy = Task.create!(name: "Busy", agent: @agent, creative: @creative, topic_id: @topic.id, status: "delegated")
      handoff_and_decide
      resume
      assert_equal "queued", continuation.status
      busy.update!(status: "done")
      Orchestration::AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
      assert_equal "pending", continuation.reload.status
    end

    test "explicit continuation stays with requesting agent despite different primary" do
      @topic.set_primary_agent!(users(:ai_bot))
      handoff_and_decide
      resume
      assert_equal "pending", continuation.status
      assert Orchestration::Matcher.prepare_waiting_task!(continuation)
    end

    test "permission downgrade and cancelled origin do not resume" do
      handoff_and_decide
      perform_enqueued_jobs(only: PermissionCacheJob) do
        CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "read")
      end
      assert_no_difference("Task.count") { resume }
      @origin.update!(status: "cancelled")
      assert_no_difference("Task.count") { resume }
    end

    test "continuation delivers one channel dispatch and duplicate execution does not recall it" do
      AgentSubscription.create!(agent: @agent, token: "live", session_id: "session")
      handoff_and_decide
      resume
      broadcasts = []
      AgentChannel.stub(:broadcast_to_agent, ->(_id, payload) { broadcasts << payload }) do
        AiAgentJob.perform_now(continuation)
        AiAgentJob.perform_now(continuation)
      end
      dispatches = broadcasts.select { |payload| payload[:type] == "dispatch" }
      assert_equal 1, dispatches.size
      assert_equal continuation.id, dispatches.first[:task_id]
      assert_equal "approval-1", dispatches.first[:approval_request_id]
      assert_includes dispatches.first.dig(:comment, :content), "revise"
      assert_equal "delegated", continuation.status
    end

    test "offline continuation suspends and reconnect keeps the same task" do
      handoff_and_decide
      resume
      task = continuation
      AiAgentJob.perform_now(task)
      assert_equal "suspended", task.reload.status
      AgentSubscription.create!(agent: @agent, token: "reconnected", session_id: "session")
      assert_no_difference("Task.count") do
        ClaudeApprovalResumeJob.perform_now(nil, @agent.id)
        ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
      end
      assert_equal task.id, continuation.id
      assert_includes %w[pending queued], continuation.status
    end

    test "rolled back reply never hands ownership to the resume job" do
      decide
      Comment.transaction do
        ClaudeApprovalHandoff.finish!(@origin, [ "approval-1" ])
        raise ActiveRecord::Rollback
      end
      assert_no_difference("Task.count") { resume }
      refute JSON.parse(@approval.reload.action)["turn_finished"]
    end

    test "private approval never creates a public decision notice" do
      @approval.update!(private: true)
      handoff_and_decide
      assert_no_difference("Comment.count") do
        assert_no_difference("Task.count") { resume }
      end
    end

    test "permission downgrade after queueing prevents execution" do
      handoff_and_decide
      resume
      perform_enqueued_jobs(only: PermissionCacheJob) do
        CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "read")
      end
      refute Orchestration::Matcher.prepare_waiting_task!(continuation)
    end

    test "approval continuation and ordinary queued chat never absorb each other" do
      Task.create!(name: "Busy", agent: @agent, creative: @creative, topic_id: @topic.id, status: "delegated")
      handoff_and_decide
      resume
      notice = @creative.comments.create!(topic: @topic, user: @user, content: "Other work", skip_dispatch: true)
      other = Task.create!(name: "Other work", agent: @agent, creative: @creative,
                           topic_id: @topic.id, status: "queued", trigger_event_name: "comment_created",
                           trigger_event_payload: notice.dispatch_payload.deep_stringify_keys)
      assert_empty Orchestration::TaskCoalescer.coalesce!(other, scope: :all)
      assert_empty Orchestration::TaskCoalescer.coalesce!(continuation, scope: :all)
      assert_equal "queued", other.reload.status
      assert_equal "queued", continuation.status
    end

    private

    def decide
      @approval.decide_claude_channel_permission!(:deny, by: @user, reason: "revise")
    end

    def handoff_and_decide
      ClaudeApprovalHandoff.finish!(@origin, [ "approval-1" ])
      decide
    end

    def resume
      ClaudeApprovalResumeJob.perform_now(@approval.id)
    end

    def continuation
      Task.find(JSON.parse(@approval.reload.action).fetch("resume_task_id"))
    end
  end
end
