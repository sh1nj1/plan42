# frozen_string_literal: true

require "test_helper"

module Collavre
  class AsyncApprovalTest < ActiveSupport::TestCase
    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      @user = users(:one)
      @agent = users(:ai_bot)
      gateway = AgentGateway.create!(name: "Test", owner: @user, base_url: "https://gateway.example.com",
                                     admin_key: "test", completion_key: "test", tenant_id: "test")
      @agent.update!(agent_gateway: gateway, llm_vendor: "cli_proxy", llm_model: "codex", created_by_id: @user.id)
      @creative = Creative.create!(description: "Async approval", user: @user)
      CreativeShare.create!(creative: @creative, user: @agent, permission: "feedback")
      @topic = @creative.main_topic
      @anchor = @creative.comments.create!(topic: @topic, user: @user, content: "Plan a release", skip_dispatch: true)
      @task = Task.create!(name: "Codex", agent: @agent, creative: @creative, topic_id: @topic.id,
                          status: "running", trigger_event_payload: @anchor.dispatch_payload)
      Current.user = @user
      Current.agent_turn = nil
      ActiveJob::Base.queue_adapter = :test
    end

    teardown do
      Current.reset
      ActiveJob::Base.queue_adapter = @previous_adapter
    end

    def request(**args)
      Tools::ApprovalRequestService.new.call(question: "Deploy?", task_id: @task.id, **args)
    end

    def gate = @task.async_approval_gates.first
    def decide(value = "approved") = Comments::ApprovalGateDecision.new(gate, @user).call(value, reason: "Reviewed")
    def resume = AsyncApprovalResumeJob.perform_now(gate.id)
    def continuation = Task.find(gate.reload.approval_gate_action["resume_task_id"])

    test "request is durable idempotent and leaves worker running" do
      first = request
      assert_equal "pending", first[:status]
      assert first[:request_id].present?
      assert_equal first, request
      assert_equal 1, @task.async_approval_gates.size
      assert_equal @user, gate.approver
      assert gate.approval_gate?
      assert @task.reload.running?
      assert_nil @task.pending_tool_call
    end

    test "meta tool discovers task_id and executes the asynchronous request" do
      meta = ::Tools::MetaToolService.new
      metadata = meta.call(action: "get", tool_name: "approval_request")
      assert_includes metadata.fetch(:tool).fetch(:params).map { |param| param[:name].to_s }, "task_id"
      result = meta.call(action: "run", tool_name: "approval_request",
                         arguments: { "question" => "Deploy?", "task_id" => @task.id })
      assert_equal "pending", result.dig(:result, :status)
      assert_equal @user, gate.approver
    end

    test "the agent itself can request approval" do
      Current.user = @agent
      assert_equal "pending", request[:status]
    end

    test "foreign callers absent callers native agents and inactive tasks are rejected" do
      Current.user = users(:two)
      assert request[:error]
      Current.user = nil
      assert request[:error]
      Current.user = @user
      @task.update!(status: "done")
      assert request[:error]
      @task.update!(status: "running")
      @agent.update!(llm_vendor: "openai")
      assert request[:error]
      assert_empty @task.async_approval_gates
    end

    test "missing task question invalid human and inaccessible human are rejected" do
      assert Tools::ApprovalRequestService.new.call(question: "Deploy?", task_id: -1)[:error]
      assert Tools::ApprovalRequestService.new.call(question: " ", task_id: @task.id)[:error]
      assert request(approver_user_id: @agent.id)[:error]
      assert request(approver_user_id: users(:two).id)[:error]
      assert_empty @task.async_approval_gates
    end

    %w[approved denied].each do |value|
      test "#{value} before turn end resumes only after completion and only once" do
        request
        decide(value)
        assert_no_difference("Task.count") { resume }
        assert_enqueued_with(job: AsyncApprovalResumeJob, args: [ gate.id ]) { @task.update!(status: "done") }
        assert_difference("Task.count", 1) { resume }
        result = continuation
        assert_equal @agent.id, result.agent_id
        assert_equal @topic.id, result.topic_id
        assert_equal @user.id, result.trigger_event_payload["workspace_user_id"]
        assert_includes result.trigger_event_payload.dig("comment", "content"), value
        assert_equal value, gate.reload.approval_gate_action.dig("decision", "decision")
        assert_no_difference("Task.count") { 2.times { resume } }
        assert_raises(Comments::ApprovalGateDecision::InvalidDecision) { decide(value) }
      end
    end

    test "decision after completion creates continuation" do
      request
      @task.update!(status: "done")
      assert_no_difference("Task.count") { resume }
      assert_enqueued_with(job: AsyncApprovalResumeJob, args: [ gate.id ]) { decide }
      assert_difference("Task.count", 1) { resume }
    end

    test "unauthorized decision and cancelled origin cannot resume" do
      request
      assert_raises(Comments::ApprovalGateDecision::InvalidDecision) do
        Comments::ApprovalGateDecision.new(gate, users(:two)).call("approved")
      end
      @task.update!(status: "cancelled")
      assert_raises(Comments::ApprovalGateDecision::InvalidDecision) { decide }
      assert_no_difference("Task.count") { resume }
    end

    test "deleted or moved gate does not cancel worker or resume" do
      request
      id = gate.id
      gate.destroy!
      assert @task.reload.running?
      assert_no_difference("Task.count") { AsyncApprovalResumeJob.perform_now(id) }
      request
      moved = gate
      moved.update!(topic: @creative.topics.create!(name: "Other", user: @user))
      assert @task.reload.running?
      assert_raises(Comments::ApprovalGateDecision::InvalidDecision) do
        Comments::ApprovalGateDecision.new(moved, @user).call("approved")
      end
    end

    test "private gate and revoked agent permission cannot publish a decision" do
      request
      decide
      @task.update!(status: "done")
      approval = gate
      approval.update!(private: true)
      assert_no_difference("Task.count") { resume }
      approval.update!(private: false)
      perform_enqueued_jobs(only: PermissionCacheJob) do
        CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "read")
      end
      assert_no_difference("Task.count") { resume }
    end

    test "explicit nil workspace principal is preserved" do
      @task.update!(trigger_event_payload: @task.trigger_event_payload.merge("workspace_user_id" => nil))
      assert request[:error]
      request(approver_user_id: @user.id)
      decide
      @task.update!(status: "done")
      resume
      assert_nil continuation.trigger_event_payload["workspace_user_id"]
    end

    test "busy topic preserves the decision anchor and explicit agent through promotion" do
      request
      decide
      @task.update!(status: "done")
      busy = Task.create!(name: "Busy", agent: @agent, creative: @creative, topic_id: @topic.id, status: "running")
      @topic.set_primary_agent!(users(:two))
      resume
      next_task = continuation
      assert next_task.queued?
      anchor_id = next_task.trigger_event_payload.dig("comment", "id")
      busy.update!(status: "done")
      Orchestration::AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
      assert next_task.reload.pending?
      assert_equal anchor_id, next_task.trigger_event_payload.dig("comment", "id")
      assert Orchestration::Matcher.prepare_waiting_task!(next_task)
      assert_equal @agent.id, next_task.agent_id
    end

    test "queued continuation rejects permission revoked before execution" do
      request
      decide
      @task.update!(status: "done")
      resume
      next_task = continuation
      perform_enqueued_jobs(only: PermissionCacheJob) do
        CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "read")
      end
      refute Orchestration::Matcher.prepare_waiting_task!(next_task)
    end

    test "continuation defaults the next approval to the original human" do
      request
      decide
      @task.update!(status: "done")
      resume
      @task = continuation
      @task.update!(status: "running")
      assert_equal "pending", request[:status]
      assert_equal @user, gate.approver
    end

    test "revoked caller permission cannot create a gate" do
      Current.user = @agent
      perform_enqueued_jobs(only: PermissionCacheJob) do
        CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "read")
      end
      assert request[:error]
      assert_empty @task.async_approval_gates
    end

    test "prompt includes task identity in the trigger even for incremental sessions" do
      data = AiAgent::MessageBuilder.new(agent: @agent, context: @task.trigger_event_payload,
                                        original_comment: @anchor, task: @task).build
      trigger = data[:messages].find { |message| message[:kind] == :trigger }
      assert_includes trigger[:parts].first[:text], @task.id.to_s
      assert_includes trigger[:parts].first[:text], "approval_request"
    end
  end
end
