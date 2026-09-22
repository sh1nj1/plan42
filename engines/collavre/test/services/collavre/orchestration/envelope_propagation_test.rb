require "test_helper"

module Collavre
  module Orchestration
    class EnvelopePropagationTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      Envelope = Collavre::SystemEvents::Envelope

      setup do
        @original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @human = users(:one)
        @creative = creatives(:tshirt)
        @agent = User.create!(
          email: "envelope_propagation_agent@example.com",
          name: "Envelope Propagation Agent",
          password: "password123",
          llm_vendor: "google",
          llm_model: "gemini-1.5-flash",
          routing_expression: "true",
          searchable: true
        )
        share = CreativeShare.find_or_create_by!(creative: @creative, user: @agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: @agent.id, permission: :feedback
        )
        @envelope = Envelope.child(
          "comment_created",
          parent: Envelope.root("comment_created", source: "comment_callback"),
          source: "a2a"
        )
      end

      teardown do
        ActiveJob::Base.queue_adapter = @original_adapter
      end

      test "the envelope survives task persistence, re-anchoring, and coalescing" do
        anchor = comment!("first")
        later = comment!("second")
        task = Task.create!(
          name: "Response to comment_created",
          status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: payload(anchor),
          agent: @agent,
          topic_id: anchor.topic_id,
          creative_id: @creative.id
        )

        assert_equal @envelope, Envelope.in(task.reload.trigger_event_payload)

        moved = TaskCoalescer.reanchor_payload(payload(anchor), later)
        assert_equal later.id, moved.dig("comment", "id")
        assert_equal @envelope, Envelope.in(moved)

        merged = TaskCoalescer.absorb_into_payload(payload(anchor), [ later.id ])
        assert_includes merged[TaskCoalescer::PAYLOAD_KEY], later.id
        assert_equal @envelope, Envelope.in(merged)
      end

      test "a promoted waiter preserves its event envelope" do
        anchor = comment!("first")
        waiter = Task.create!(
          name: "Response to comment_created",
          status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: payload(anchor),
          agent: @agent,
          topic_id: anchor.topic_id,
          creative_id: @creative.id
        )

        AgentOrchestrator.dequeue_next_for_topic(waiter.topic_id, waiter.creative_id)

        assert_equal "pending", waiter.reload.status
        assert_equal @envelope, Envelope.in(waiter.trigger_event_payload)
      end

      private

      def comment!(content)
        Comment.create!(creative: @creative, user: @human, content: content, skip_dispatch: true)
      end

      def payload(comment)
        comment.dispatch_payload.deep_stringify_keys.merge(Envelope::KEY => @envelope.to_h)
      end
    end
  end
end
