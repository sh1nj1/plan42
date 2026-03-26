# frozen_string_literal: true

require "test_helper"

module Collavre
  class Comment
    class NotifiableTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @agent = users(:two)
        # Make :two an AI user by setting llm_vendor
        @agent.update_columns(llm_vendor: "openai")

        @creative = Creative.create!(user: @owner, description: "Test Creative")
        @topic = Topic.create!(creative: @creative, name: "test", user: @owner)
      end

      test "notify_ai_completion creates inbox item for absent users" do
        comment = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT,
          user: @agent,
          topic: @topic
        )
        # Simulate finalization: update content
        comment.update!(content: "AI response complete")

        # Owner is not present (CommentPresenceStore is empty by default)
        assert_difference "InboxItem.count", 1 do
          comment.notify_ai_completion
        end

        inbox_item = InboxItem.last
        assert_equal @owner, inbox_item.owner
        assert_equal "inbox.comment_added", inbox_item.message_key
      end

      test "notify_ai_completion skips present users" do
        comment = @creative.comments.create!(
          content: "AI response complete",
          user: @agent,
          topic: @topic
        )

        # Mark owner as present
        CommentPresenceStore.add(@creative.id, @owner.id)

        assert_no_difference "InboxItem.count" do
          comment.notify_ai_completion
        end
      ensure
        CommentPresenceStore.remove(@creative.id, @owner.id)
      end

      test "notify_ai_completion does nothing for non-AI users" do
        comment = @creative.comments.create!(
          content: "Human message",
          user: @owner,
          topic: @topic
        )

        assert_no_difference "InboxItem.count" do
          comment.notify_ai_completion
        end
      end
    end
  end
end
