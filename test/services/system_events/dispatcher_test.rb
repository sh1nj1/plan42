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
      assert_enqueued_with(job: AiAgentJob, args: [ @agent.id, "test_event", @context ]) do
        SystemEvents::Dispatcher.dispatch("test_event", @context)
      end
    end

    test "does not enqueue job if no agent matches" do
      @agent.update!(routing_expression: "false")

      assert_no_enqueued_jobs do
        SystemEvents::Dispatcher.dispatch("test_event", @context)
      end
    end
  end
end
