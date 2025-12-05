require "test_helper"

module SystemEvents
  class DispatcherTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @agent = User.create!(
        email: "dispatcher_test_agent@example.com",
        name: "Dispatcher Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true",
        searchable: true
      )

      @context = { "some" => "context" }
    end

    test "dispatches event and enqueues job for matched agent" do
      # ContextBuilder deep_stringifies keys, so we expect string keys
      expected_context = @context.deep_stringify_keys

      assert_enqueued_with(job: AiAgentJob, args: [ @agent.id, "test_event", expected_context ]) do
        SystemEvents::Dispatcher.dispatch("test_event", @context)
      end
    end

    test "does not enqueue job if no agent matches" do
      @agent.update!(routing_expression: "false")

      assert_no_enqueued_jobs do
        SystemEvents::Dispatcher.dispatch("test_event", @context)
      end
    end

    test "preserves mentioned_user in context" do
      chat_context = { "chat" => { "content" => "@Dispatcher Agent: Hello" } }

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
