require "test_helper"

module SystemEvents
  class DispatcherTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    Envelope = Collavre::SystemEvents::Envelope
    Vocabulary = Collavre::SystemEvents::Vocabulary

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
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
      share = Collavre::CreativeShare.find_or_create_by!(creative: @creative, user: @agent)
      share.update!(permission: "feedback")
      Collavre::CreativeSharesCache.find_or_create_by!(
        creative_id: @creative.id, user_id: @agent.id, permission: :feedback
      )
      @context = { "creative" => { "id" => @creative.id }, "some" => "context" }
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    def enqueued_context
      ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args][2]
    end

    test "dispatches the registered event and stamps a root envelope" do
      assert_enqueued_with(job: AiAgentJob) do
        SystemEvents::Dispatcher.dispatch("comment_created", @context, source: "cron")
      end

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      assert_equal @agent.id, job[:args][0]
      assert_equal "comment_created", job[:args][1]
      assert_equal "comment_created", enqueued_context["event_name"]

      envelope = Envelope.in(enqueued_context)
      assert_equal "cron", envelope.source
      assert_equal 0, envelope.depth
      assert_equal envelope.id, envelope.correlation_id
      assert_nil envelope.causation_id
    end

    test "preserves a same-name envelope already in the payload" do
      existing = Envelope.root("comment_created", source: "drop_trigger")

      SystemEvents::Dispatcher.dispatch(
        "comment_created", @context.merge(Envelope::KEY => existing.to_h)
      )

      assert_equal existing, Envelope.in(enqueued_context)
    end

    test "an explicit parent makes a child and outranks the payload envelope" do
      existing = Envelope.root("comment_created", source: "drop_trigger")
      parent = Envelope.root("comment_created", source: "comment_callback")

      SystemEvents::Dispatcher.dispatch(
        "comment_created",
        @context.merge(Envelope::KEY => existing.to_h),
        source: "a2a",
        parent: parent
      )

      envelope = Envelope.in(enqueued_context)
      assert_equal parent.correlation_id, envelope.correlation_id
      assert_equal parent.id, envelope.causation_id
      assert_equal 1, envelope.depth
      assert_equal "a2a", envelope.source
    end

    test "an envelope for a different event becomes the parent" do
      existing = Envelope.root("other_event", source: "cron")

      SystemEvents::Dispatcher.dispatch(
        "comment_created", @context.merge(Envelope::KEY => existing.to_h), source: "a2a"
      )

      envelope = Envelope.in(enqueued_context)
      assert_equal existing.id, envelope.causation_id
      assert_equal existing.correlation_id, envelope.correlation_id
    end

    test "normalizes a symbol-keyed context without mutating the caller" do
      context = { creative: { id: @creative.id } }

      SystemEvents::Dispatcher.dispatch("comment_created", context, source: "cron")

      assert_equal [ :creative ], context.keys
      assert_equal "cron", Envelope.in(enqueued_context).source
    end

    test "does not enqueue work when no agent matches" do
      @agent.update!(routing_expression: "false")

      assert_no_enqueued_jobs do
        SystemEvents::Dispatcher.dispatch("comment_created", @context)
      end
    end

    test "preserves mentioned_user in context" do
      chat_context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "@Dispatcher Agent: Hello" }
      }

      SystemEvents::Dispatcher.dispatch("comment_created", chat_context)

      assert_equal @agent.id, enqueued_context.dig("chat", "mentioned_user", "id")
    end

    test "unknown event names fail before scheduling" do
      assert_no_enqueued_jobs do
        assert_raises(Vocabulary::UnknownEvent) do
          SystemEvents::Dispatcher.dispatch("deploy_requested", @context)
        end
      end
    end

    test "missing required payload keys warn but still dispatch" do
      warnings = []
      Rails.logger.stub(:warn, ->(message) { warnings << message }) do
        SystemEvents::Dispatcher.dispatch("comment_created", @context, source: "cron")
      end

      assert warnings.any? { |message| message.include?("missing_keys=comment") }
      assert_enqueued_jobs 1, only: AiAgentJob
    end
  end
end
