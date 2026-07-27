# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # A direct @mention outranks a topic's primary-agent assignment. Coalescing
    # moves the mentioning comment out of the anchor and into "merged_comment_ids",
    # so revalidation that reads only the anchor cancels a waiter that was
    # explicitly addressed — and takes every comment the waiter had absorbed
    # down with it.
    class MergedMentionRevalidationTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @primary = Collavre::User.create!(
          name: "pinned-agent-#{SecureRandom.hex(3)}",
          email: "pinned-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai", llm_model: "gpt-4"
        )
        @topic = Topic.create!(
          name: "Assignment topic", creative: @creative, user: @user, primary_agent: @primary
        )
      end

      def comment(body)
        Comment.create!(
          creative: @creative, user: @user, topic: @topic, content: body, skip_dispatch: true
        )
      end

      def waiter_for(anchor, merged: [])
        payload = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "comment" => {
            "id" => anchor.id, "content" => anchor.content, "user_id" => anchor.user_id
          },
          "chat" => { "content" => anchor.content }
        }
        payload[TaskCoalescer::PAYLOAD_KEY] = merged if merged.any?

        Task.create!(
          name: "Response to comment_created", status: "queued",
          trigger_event_name: "comment_created", agent: @agent,
          topic_id: @topic.id, creative_id: @creative.id, trigger_event_payload: payload
        )
      end

      test "a waiter survives when an absorbed comment mentions its agent" do
        mention = comment("@#{@agent.name}: please handle this one")
        task = waiter_for(mention)
        comment("an ambient message that mentions nobody")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        refute_equal "cancelled", task.reload.status,
          "the absorbed direct mention outranks the primary-agent assignment"
        assert_includes Array(task.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY]), mention.id
      end

      test "a waiter with no mention anywhere is still cancelled" do
        task = waiter_for(comment("ambient one"), merged: [ comment("ambient two").id ])
        comment("ambient three")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "cancelled", task.reload.status,
          "the assignment must still silence agents nobody addressed"
      end
    end
  end
end
