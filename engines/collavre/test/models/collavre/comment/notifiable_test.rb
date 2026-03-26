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
        comment.update!(content: "AI response complete")

        assert_difference "InboxItem.count", 1 do
          comment.notify_ai_completion
        end

        inbox_item = InboxItem.last
        assert_equal @owner, inbox_item.owner
        assert_equal "inbox.comment_added", inbox_item.message_key
      end

      test "notify_ai_completion sends mention notification for mentioned users" do
        comment = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT,
          user: @agent,
          topic: @topic
        )
        comment.update!(content: "Hello @#{@owner.name}: check this out")

        # Owner is mentioned → gets mention notification (not comment_added)
        inbox_items_before = InboxItem.count
        comment.notify_ai_completion
        new_items = InboxItem.where("id > ?", inbox_items_before).order(:id)

        mention_item = new_items.find { |i| i.message_key == "inbox.user_mentioned" }
        assert mention_item, "Expected a mention notification for the owner"
        assert_equal @owner, mention_item.owner
      end

      test "notify_ai_completion skips present users" do
        comment = @creative.comments.create!(
          content: "AI response complete",
          user: @agent,
          topic: @topic
        )

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

      test "notify_ai_completion truncates long message content in inbox item" do
        long_content = "A" * 200
        comment = @creative.comments.create!(
          content: long_content,
          user: @agent,
          topic: @topic
        )

        comment.notify_ai_completion
        inbox_item = InboxItem.last
        snippet = inbox_item.message_params["comment"]
        assert snippet.length <= 100, "Expected comment to be truncated to 100 chars, got #{snippet.length}"
        assert snippet.end_with?("..."), "Expected truncated comment to end with '...'"
      end

      test "notify_ai_completion rescues errors without raising" do
        comment = @creative.comments.create!(
          content: "AI response",
          user: @agent,
          topic: @topic
        )

        # Stub create_inbox_item to raise an error
        comment.stub(:create_inbox_item, ->(*_args) { raise StandardError, "test error" }) do
          assert_nothing_raised do
            comment.notify_ai_completion
          end
        end
      end
    end
  end
end
