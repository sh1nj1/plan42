require "test_helper"

module Collavre
  class OfflineRecoveryIntegrationTest < ActiveJob::TestCase
    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @user = users(:one)
      @agent = User.create!(name: "Resuming channel", email: "resume-channel@example.test",
        password: SecureRandom.hex(24), llm_vendor: "anthropic", llm_model: "claude-code",
        created_by_id: @user.id, routing_expression: "true")
      @creative = Creative.create!(user: @user, description: "Offline recovery")
      @topic = Topic.create!(creative: @creative, user: @user, name: "Recovery")
      @trigger = create_comment("Original request")
      @task = turn(@trigger, status: "delegated")
      OrchestratorPolicy.create!(policy_type: "scheduling", scope_type: nil,
        config: { "topic_max_concurrent_jobs" => 1 })
    end

    teardown { ActiveJob::Base.queue_adapter = @previous_adapter }

    test "offline suspension and duplicate reconnects preserve the original task and newer messages" do
      perform_after_grace(@agent.id, nil)
      assert_equal "suspended", @task.reload.status
      followup = create_comment("Also include the latest result")
      waiter = turn(followup, status: "queued")
      AgentSubscription.create!(agent: @agent, token: "back")

      assert_enqueued_jobs 1, only: AiAgentJob do
        2.times { ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id) }
      end
      assert_equal "pending", @task.reload.status
      assert_equal 1, @task.resume_count
      assert_equal "cancelled", waiter.reload.status
      context = @task.trigger_event_payload
      assert_equal @trigger.id, context.dig("resume_context", "trigger_comment_id")
      assert_includes (Array(context["merged_comment_ids"]) + [ context.dig("comment", "id") ]), followup.id
    end

    test "a late reply can complete an offline suspension before reconnect without redispatch" do
      perform_after_grace(@agent.id, nil)
      service = AiAgent::TaskClaimService.new
      claimed = service.claim(agent: @agent, topic: @topic, requested_task_id: @task.id)
      assert_equal @task.id, claimed&.id
      reply = create_comment("Completed while reconnecting", user: @agent)
      service.link_reply(task: claimed, comment: reply)
      service.finalize(agent: @agent, task: claimed, comment: reply)
      AgentSubscription.create!(agent: @agent, token: "late-back")

      assert_no_enqueued_jobs only: AiAgentJob do
        ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
        perform_after_grace(@agent.id, nil)
      end
      assert_equal "done", @task.reload.status
      assert_equal reply.id, @task.reply_comment.id
    end

    test "late reply from the previous execution cannot claim a resumed delegated turn" do
      @task.update!(trigger_event_payload: @task.trigger_event_payload.merge("execution_generation" => "old-attempt"))
      perform_after_grace(@agent.id, nil)
      AgentSubscription.create!(agent: @agent, token: "back")
      ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
      @task.reload.update!(status: "delegated",
        trigger_event_payload: @task.trigger_event_payload.merge("execution_generation" => "new-attempt"))
      service = AiAgent::TaskClaimService.new
      assert_nil service.claim(agent: @agent, topic: @topic, requested_task_id: @task.id,
        requested_generation: "old-attempt")
      assert_equal "delegated", @task.reload.status
      assert_equal @task.id, service.claim(agent: @agent, topic: @topic, requested_task_id: @task.id,
        requested_generation: "new-attempt").id
    end

    test "disconnect between resume enqueue and execution suspends the same task again" do
      perform_after_grace(@agent.id, nil)
      presence = AgentSubscription.create!(agent: @agent, token: "briefly-back")
      ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
      assert_equal "pending", @task.reload.status
      presence.destroy!
      AiAgentJob.perform_now(@task)
      assert_equal "suspended", @task.reload.status
      assert_equal "agent_offline", @task.suspend_reason
    end

    test "private session work waits for its own reconnect even when a sibling is online" do
      @topic.update!(primary_agent_id: @agent.id, session_id: "original-session")
      AgentSubscription.create!(agent: @agent, token: "sibling", session_id: "sibling-session")
      perform_after_grace(@agent.id, nil, "original-session")
      ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
      assert_equal "suspended", @task.reload.status
      AgentSubscription.create!(agent: @agent, token: "original-back", session_id: "original-session")
      ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
      assert_equal "pending", @task.reload.status
    end

    private

    def perform_after_grace(*arguments)
      Orchestration::OfflineTaskGrace.write_deadline(@task, 1.second.ago)
      CancelOfflineDelegatedTasksJob.perform_now(*arguments)
    end

    def create_comment(content, user: @user)
      Comment.create!(creative: @creative, topic: @topic, user: user, content: content, skip_dispatch: true)
    end

    def turn(comment, status:)
      Task.create!(name: "Channel turn", agent: @agent, creative_id: @creative.id, topic_id: @topic.id,
        trigger_event_name: "comment_created", status: status,
        trigger_event_payload: {
          "creative" => { "id" => @creative.id }, "topic" => { "id" => @topic.id },
          "comment" => { "id" => comment.id, "content" => comment.content, "user_id" => @user.id }
        })
    end
  end
end
