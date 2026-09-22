require "test_helper"

module Collavre
  module AiAgent
    class A2aDispatcherEnvelopeTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      Envelope = Collavre::SystemEvents::Envelope

      setup do
        @original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @creative = creatives(:tshirt)
        @speaker = build_agent("a2a_speaker@example.com", "A2A Speaker")
        @listener = build_agent("a2a_listener@example.com", "A2A Listener")
        @reply = Comment.create!(
          creative: @creative,
          user: @speaker,
          content: "@A2A Listener: your turn",
          skip_dispatch: true
        )
      end

      teardown do
        ActiveJob::Base.queue_adapter = @original_adapter
      end

      test "an A2A dispatch is a child of the turn that produced it" do
        parent = Envelope.root("comment_created", source: "comment_callback")

        dispatch_with(parent)

        envelope = dispatched_envelope
        assert_equal "a2a", envelope.source
        assert_equal parent.id, envelope.causation_id
        assert_equal parent.correlation_id, envelope.correlation_id
        assert_equal 1, envelope.depth
      end

      test "A2A chains retain their original correlation and keep increasing depth" do
        root = Envelope.root("comment_created", source: "comment_callback")
        parent = Envelope.child("comment_created", parent: root, source: "a2a")

        dispatch_with(parent)

        envelope = dispatched_envelope
        assert_equal root.correlation_id, envelope.correlation_id
        assert_equal parent.id, envelope.causation_id
        assert_equal 2, envelope.depth
      end

      test "a missing parent envelope still dispatches as an A2A root" do
        dispatch_with(nil)

        envelope = dispatched_envelope
        assert_equal "a2a", envelope.source
        assert envelope.root?
        assert_equal 0, envelope.depth
      end

      test "the Claude Channel reply path carries the task envelope into A2A context" do
        parent = Envelope.root("comment_created", source: "comment_callback")
        task = Task.create!(
          name: "Response to comment_created",
          status: "running",
          trigger_event_name: "comment_created",
          trigger_event_payload: { Envelope::KEY => parent.to_h },
          agent: @speaker,
          topic_id: @reply.topic_id,
          creative_id: @creative.id
        )
        captured_context = nil
        dispatcher = Object.new
        dispatcher.define_singleton_method(:dispatch) { }

        A2aDispatcher.stub(:new, lambda { |**options|
          captured_context = options.fetch(:context)
          dispatcher
        }) do
          Api::V1::AgentsController.new.send(:dispatch_a2a, @speaker, @reply, task: task)
        end

        assert_equal parent.to_h, captured_context[Envelope::KEY]
      end

      private

      def build_agent(email, name)
        agent = User.create!(
          email: email,
          name: name,
          password: "password123",
          llm_vendor: "google",
          llm_model: "gemini-1.5-flash",
          searchable: true
        )
        share = CreativeShare.find_or_create_by!(creative: @creative, user: agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: agent.id, permission: :feedback
        )
        agent
      end

      def dispatch_with(parent)
        context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @reply.topic_id }
        }
        context[Envelope::KEY] = parent.to_h if parent

        A2aDispatcher.new(agent: @speaker, reply_comment: @reply, context: context).dispatch
      end

      def dispatched_envelope
        Envelope.in(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args][2])
      end
    end
  end
end
