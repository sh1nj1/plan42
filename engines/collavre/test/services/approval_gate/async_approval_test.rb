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

    test "callback workspace permits collaborator only for their own agent turn" do
      collaborator = users(:two)
      perform_enqueued_jobs(only: PermissionCacheJob) do
        CreativeShare.create!(creative: @creative, user: collaborator, permission: "feedback")
      end
      @task.update!(trigger_event_payload: @task.trigger_event_payload.merge("workspace_user_id" => collaborator.id))
      Current.user = collaborator
      Current.mcp_agent_workspace = AgentWorkspace.new(agent: @agent, user: collaborator)
      assert_equal "pending", request[:status]
      assert_equal collaborator, gate.approver
      Current.mcp_agent_workspace = AgentWorkspace.new(agent: @user, user: collaborator)
      assert request[:error]
      Current.mcp_agent_workspace = AgentWorkspace.new(agent: @agent, user: @user)
      assert request[:error]
      Current.mcp_agent_workspace = AgentWorkspace.new(agent: @agent, user: collaborator)
      @task.update!(trigger_event_payload: @task.trigger_event_payload.merge("workspace_user_id" => @user.id))
      assert request[:error]
    end

    test "creator callback uses dispatch fallback but respects explicit absent principal" do
      @task.update!(trigger_event_payload: {})
      Current.mcp_agent_workspace = AgentWorkspace.new(agent: @agent, user: @user)
      assert_equal "pending", request(approver_user_id: @user.id)[:status]
      @task.update!(trigger_event_payload: { "workspace_user_id" => nil })
      assert request(approver_user_id: @user.id)[:error]
    end

    test "shared callback workspace permits its agent" do
      Current.user = @agent
      Current.mcp_agent_workspace = AgentWorkspace.new(agent: @agent)
      assert_equal "pending", request[:status]
    end

    test "task lookup excludes historical action comments through indexed origin ID" do
      request
      historical = gate.dup
      historical.async_approval_task_id = @task.id + 1
      historical.save!
      assert_equal [ gate.id ], @task.async_approval_gates.pluck(:id)
      assert_match(/async_approval_task_id/, @task.async_approval_gates.to_sql)
      assert ActiveRecord::Base.connection.index_exists?(:comments, :async_approval_task_id)
    end

    %w[queued pending running].each do |status|
      %w[destroy move].each do |operation|
        test "#{operation} gate cancels only unstarted #{status} continuation" do
          request
          decide
          @task.update!(status: "done")
          approval = gate
          resume
          next_task = continuation
          next_task.update!(status: status)
          if operation == "destroy"
            approval.destroy!
          else
            approval.update!(topic: @creative.topics.create!(name: "Withdrawn", user: @user))
          end
          assert_equal(status == "running" ? "running" : "cancelled", next_task.reload.status)
          assert @task.reload.done?
          assert_no_difference("Task.count") { AsyncApprovalResumeJob.perform_now(approval.id) }
        end
      end
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

    test "sweep recovers a committed decision with no queued resume and is idempotent" do
      request
      @task.update!(status: "done")
      decide
      clear_enqueued_jobs

      assert_difference("Task.count", 1) { AsyncApprovalSweepJob.perform_now }
      assert_equal @agent.id, continuation.agent_id
      assert_enqueued_with(job: AiAgentJob, args: [ continuation ])
      assert_no_difference("Task.count") { AsyncApprovalSweepJob.perform_now }
    end

    test "sweep retries dispatch after continuation creation survives enqueue failure" do
      request
      @task.update!(status: "done")
      decide
      AiAgentJob.stub(:perform_later, ->(*) { raise "Queue unavailable" }) do
        AsyncApprovalSweepJob.perform_now
      end
      saved_id = continuation.id
      assert continuation.queued?
      clear_enqueued_jobs

      assert_no_difference("Task.count") { AsyncApprovalSweepJob.perform_now }
      assert_equal saved_id, continuation.id
      assert_enqueued_with(job: AiAgentJob, args: [ continuation ])
    end

    test "sweep isolates failures and retries on the next pass" do
      request
      @task.update!(status: "done")
      decide
      other_gate = gate.dup
      other_gate.save!
      attempted = []
      AsyncApprovalResumeJob.stub(:perform_now, ->(id) { attempted << id; raise "Queue unavailable" }) do
        AsyncApprovalSweepJob.perform_now
      end
      assert_includes attempted, gate.id
      assert_includes attempted, other_gate.id
      other_gate.destroy!
      assert_difference("Task.count", 1) { AsyncApprovalSweepJob.perform_now }
    end

    test "sweep skips undecided native and malformed gates and waits for turn completion" do
      request
      assert_no_difference("Task.count") { AsyncApprovalSweepJob.perform_now }
      decide
      assert_no_difference("Task.count") { AsyncApprovalSweepJob.perform_now }
      native = gate.dup
      native.action = { action: "approval_gate", decision: "approved" }.to_json
      native.save!
      malformed = gate.dup
      malformed.action = "approval_gate invalid JSON"
      malformed.save!(validate: false)
      called = []
      AsyncApprovalResumeJob.stub(:perform_now, ->(id) { called << id }) { AsyncApprovalSweepJob.perform_now }
      assert_equal [ gate.id ], called
      @task.update!(status: "done")
      assert_difference("Task.count", 1) { AsyncApprovalSweepJob.perform_now }
      continuation.update!(status: "done")
      assert_no_enqueued_jobs(only: AiAgentJob) { AsyncApprovalSweepJob.perform_now }
    end

    %w[running done failed cancelled].each do |status|
      test "sweep retires a #{status} continuation and never processes its gate again" do
        request
        decide
        @task.update!(status: "done")
        resume
        continuation.update!(status: status)

        AsyncApprovalResumeJob.stub(:perform_now, ->(*) { flunk "Historical gate was resumed" }) do
          2.times { AsyncApprovalSweepJob.perform_now }
        end
        refute gate.reload.async_approval_recovery_pending?
      end
    end

    %w[failed cancelled].each do |status|
      test "sweep retires a #{status} origin" do
        request
        decide
        @task.update!(status: status)
        AsyncApprovalResumeJob.stub(:perform_now, ->(*) { flunk "Inactive origin was resumed" }) do
          2.times { AsyncApprovalSweepJob.perform_now }
        end
        refute gate.reload.async_approval_recovery_pending?
      end
    end

    test "sweep retains pending recovery until the origin finishes and dispatch succeeds" do
      request
      refute gate.async_approval_recovery_pending?
      decide
      AsyncApprovalSweepJob.perform_now
      assert gate.reload.async_approval_recovery_pending?
      @task.update!(status: "done")
      AsyncApprovalSweepJob.perform_now
      assert gate.reload.async_approval_recovery_pending?
      assert continuation.pending?
      continuation.update!(status: "running")
      AsyncApprovalSweepJob.perform_now
      refute gate.reload.async_approval_recovery_pending?
    end

    test "sweep retires withdrawn gates and missing continuations" do
      request
      decide
      @task.update!(status: "done")
      resume
      continuation.destroy!
      assert_no_difference("Task.count") { AsyncApprovalSweepJob.perform_now }
      refute gate.reload.async_approval_recovery_pending?
      gate.update!(async_approval_recovery_pending: true, private: true)
      AsyncApprovalSweepJob.perform_now
      refute gate.reload.async_approval_recovery_pending?
    end

    test "sweep retires moved gates and revoked agent access" do
      request
      decide
      original_gate = gate
      original_gate.update!(topic: @creative.topics.create!(name: "Moved", user: @user))
      AsyncApprovalSweepJob.perform_now
      refute original_gate.reload.async_approval_recovery_pending?
      original_gate.update!(topic: @topic, async_approval_recovery_pending: true)
      perform_enqueued_jobs(only: PermissionCacheJob) do
        CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "read")
      end
      AsyncApprovalSweepJob.perform_now
      refute original_gate.reload.async_approval_recovery_pending?
    end

    test "async approval recovery is scheduled in every running environment" do
      config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
      %w[production desktop development].each do |environment|
        recovery = config.fetch(environment).fetch("async_approval_recovery")
        assert_equal "Collavre::AsyncApprovalSweepJob", recovery.fetch("class")
        assert_equal "every minute", recovery.fetch("schedule")
      end
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
