require "test_helper"

module SystemEvents
  class DispatcherTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      # Use test adapter for this file to test job enqueueing behavior
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = users(:one)
      @creative = creatives(:tshirt)

      @agent = User.create!(
        email: "dispatcher_test_agent@example.com",
        name: "Dispatcher Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true",
        searchable: true
      )

      # Grant feedback permission on the creative for AI agent
      share = Collavre::CreativeShare.find_or_create_by!(creative: @creative, user: @agent)
      share.update!(permission: "feedback")
      # Manually create cache entry (after_commit doesn't run in test transaction)
      Collavre::CreativeSharesCache.find_or_create_by!(
        creative_id: @creative.id,
        user_id: @agent.id,
        permission: :feedback
      )

      @context = { "creative" => { "id" => @creative.id }, "some" => "context" }
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    test "dispatches event and enqueues job for matched agent" do
      assert_enqueued_with(job: AiAgentJob) do
        SystemEvents::Dispatcher.dispatch("test_event", @context)
      end

      # Verify the enqueued job has the correct agent and event
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      assert_equal @agent.id, job[:args][0]
      assert_equal "test_event", job[:args][1]

      # Context should include event_name (added by Orchestrator)
      enqueued_context = job[:args][2]
      assert_equal "test_event", enqueued_context["event_name"]
    end

    test "does not enqueue job if no agent matches" do
      @agent.update!(routing_expression: "false")

      assert_no_enqueued_jobs do
        SystemEvents::Dispatcher.dispatch("test_event", @context)
      end
    end

    test "preserves mentioned_user in context" do
      chat_context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "@Dispatcher Agent: Hello" }
      }

      assert_enqueued_with(job: AiAgentJob) do
        SystemEvents::Dispatcher.dispatch("test_event", chat_context)
      end

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      enqueued_context = job[:args][2]

      assert enqueued_context["chat"].key?("mentioned_user")
      assert_equal @agent.id, enqueued_context["chat"]["mentioned_user"]["id"]
    end
  end
end
