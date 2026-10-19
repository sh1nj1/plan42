# frozen_string_literal: true

require "test_helper"

module Collavre
  # A keep turn that asks for approval and ends BLOCKED must hand the loop to the
  # approval continuation, whatever order the decision and the turn's check run in.
  class ApprovalContinuationTriggerLoopTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      @user = users(:one)
      @agent = users(:ai_bot)
      gateway = AgentGateway.create!(name: "Test", owner: @user, base_url: "https://gateway.example.com",
                                     admin_key: "test", completion_key: "test", tenant_id: "test")
      @agent.update!(agent_gateway: gateway, llm_vendor: "cli_proxy", llm_model: "codex", created_by_id: @user.id)
      @creative = Creative.create!(description: "Keep approval", user: @user)
      CreativeShare.create!(creative: @creative, user: @agent, permission: "feedback")
      @topic = @creative.main_topic
      @turn = @creative.comments.create!(topic: @topic, user: @user, content: "iteration", skip_dispatch: true)
      @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
        @topic.id, source: "keep", agent_id: @agent.id, start_comment_id: @turn.id,
                   current_comment_id: @turn.id, cooldown_seconds: 0, control_version: 1
      ) } })
      payload = @turn.dispatch_payload.deep_stringify_keys
      payload["comment"]["keep_loop_generation"] = 1
      @task = Task.create!(name: "Keep turn", agent: @agent, creative: @creative, topic_id: @topic.id, status: "running",
                           trigger_event_name: "comment_created", trigger_event_payload: payload)
      Current.user = @user
      Current.agent_turn = nil
      ActiveJob::Base.queue_adapter = :test
      result = Tools::ApprovalRequestService.new.call(question: "Deploy?", task_id: @task.id)
      raise result.inspect unless result[:status] == "pending"
      @creative.comments.create!(topic: @topic, user: @agent, task: @task, content: "Need approval [STATUS: BLOCKED]",
                                 skip_dispatch: true)
      @task.update!(status: "done")
    end

    teardown do
      Current.reset
      ActiveJob::Base.queue_adapter = @previous_adapter
    end

    def gate = @task.async_approval_gates.first
    def loop_config = @creative.reload.data.dig("trigger", "loop")
    def continuation = Task.find(gate.reload.approval_gate_action["resume_task_id"])

    def decide_and_resume
      Comments::ApprovalGateDecision.new(gate, @user).call("approved", reason: nil)
      AsyncApprovalResumeJob.perform_now(gate.id)
    end

    def finish_continuation(reply)
      @creative.comments.create!(topic: @topic, user: @agent, task: continuation, content: reply, skip_dispatch: true)
      continuation.update!(status: "done")
    end

    test "decision after the BLOCKED check paused the loop resumes it through the continuation" do
      TriggerLoopCheckJob.perform_now(@task.id)
      assert_equal "awaiting_user", loop_config["state"]

      decide_and_resume
      assert_equal "running", loop_config["state"]
      assert_equal({ "comment_id" => @turn.id, "generation" => 1 }, continuation.trigger_event_payload[KeepLoop::CONTINUATION_KEY])
      assert @creative.trigger_loop_task?(continuation)

      assert_enqueued_with(job: TriggerLoopCheckJob, args: [ continuation.id ]) { finish_continuation("Started [STATUS: CONTINUE]") }
      assert_difference -> { @topic.comments.count }, 1 do
        TriggerLoopCheckJob.perform_now(continuation.id)
      end
      assert_equal 1, loop_config["current_iteration"]
      assert_equal "running", loop_config["state"]
    end

    test "decision before the asking turn's check keeps the loop running" do
      decide_and_resume
      assert @task.reload.trigger_event_payload[KeepLoop::CONTINUED_KEY]

      assert_no_difference -> { @topic.comments.count } do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
      assert_equal "running", loop_config["state"]
      assert_enqueued_with(job: TriggerLoopCheckJob, args: [ continuation.id ]) { finish_continuation("Started [STATUS: CONTINUE]") }
    end

    # Runs the asking turn's check with the decision committed just before +hook+ executes.
    def check_with_decision_before(hook)
      job = TriggerLoopCheckJob.new
      original = job.method(hook)
      decide = method(:decide_and_resume)
      job.define_singleton_method(hook) do |*args|
        decide.call
        original.call(*args)
      end
      job.perform(@task.id)
    end

    test "decision after the check read the loop snapshot keeps the loop running" do
      check_with_decision_before(:evaluate_response)
      assert_equal "running", loop_config["state"]
      assert_enqueued_with(job: TriggerLoopCheckJob, args: [ continuation.id ]) { finish_continuation("Started [STATUS: CONTINUE]") }
    end

    test "decision after the check passed its early return keeps the loop running" do
      check_with_decision_before(:trigger_completion_topic)
      assert_equal "running", loop_config["state"]
      assert_enqueued_with(job: TriggerLoopCheckJob, args: [ continuation.id ]) { finish_continuation("Started [STATUS: CONTINUE]") }
    end

    test "decision after the check paused the loop suppresses its awaiting-user notice" do
      check_with_decision_before(:post_loop_notice)
      assert_equal "running", loop_config["state"]
      awaiting = I18n.t("collavre.trigger_loop.awaiting_user", iteration: loop_config["current_iteration"])
      assert_not @topic.comments.exists?(content: awaiting)
    end

    test "a failed continuation releases the loop it owns" do
      decide_and_resume
      continuation.update!(status: "running")
      assert_equal "running", loop_config["state"]

      continuation.update!(status: "failed")
      assert_equal "awaiting_user", loop_config["state"]
    end

    test "a long-running continuation keeps owning the loop during reconciliation" do
      decide_and_resume
      continuation.update!(status: "running")
      clear_enqueued_jobs

      travel 1.hour do
        assert Orchestration::KeepLoopOwnership.new(@creative.reload, grace: 15.minutes).live?
      end
    end

    test "an unavailable keep agent leaves the paused loop awaiting the user" do
      TriggerLoopCheckJob.perform_now(@task.id)
      CreativeShare.where(creative: @creative, user: @agent).destroy_all
      Creatives::PermissionChecker.stub(:current_allowed?, false) { decide_and_resume }
      assert_equal "awaiting_user", loop_config["state"]
    end

    test "a loop that moved past the asking turn is left alone" do
      TriggerLoopCheckJob.perform_now(@task.id)
      moved = loop_config.merge("current_comment_id" => @turn.id + 1_000, "state" => "awaiting_user")
      @creative.update!(data: { "trigger" => { "loop" => moved } })

      decide_and_resume
      assert_equal "awaiting_user", loop_config["state"]
      assert_nil continuation.trigger_event_payload[KeepLoop::CONTINUATION_KEY]
      assert_no_enqueued_jobs(only: TriggerLoopCheckJob) { finish_continuation("Done [STATUS: CONTINUE]") }
    end

    test "creatives without a loop create plain continuations" do
      @creative.update!(data: {})
      decide_and_resume
      assert_nil continuation.trigger_event_payload[KeepLoop::CONTINUATION_KEY]
      assert_nil @task.reload.trigger_event_payload[KeepLoop::CONTINUED_KEY]
    end
  end
end
