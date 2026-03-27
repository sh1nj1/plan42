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

      test "notify_ai_completion creates inbox comment for absent users" do
        comment = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT,
          user: @agent,
          topic: @topic
        )
        comment.update!(content: "AI response complete")

        inbox = Creative.inbox_for(@owner)

        assert_difference "inbox.comments.count", 1 do
          comment.notify_ai_completion
        end

        inbox_comment = inbox.comments.where(quoted_comment: comment).last
        assert inbox_comment, "Expected inbox comment for owner"
        assert_nil inbox_comment.user
        assert_equal comment.id, inbox_comment.quoted_comment_id
        assert_includes inbox_comment.content, "AI response complete"
      end

      test "notify_ai_completion sends mention notification for mentioned users" do
        comment = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT,
          user: @agent,
          topic: @topic
        )
        comment.update!(content: "Hello @#{@owner.name}: check this out")

        inbox = Creative.inbox_for(@owner)

        assert_difference "inbox.comments.count", 1 do
          comment.notify_ai_completion
        end

        mention_comment = inbox.comments.where(quoted_comment: comment).last
        assert mention_comment, "Expected a mention notification for the owner"
        assert_nil mention_comment.user
        assert_equal comment.id, mention_comment.quoted_comment_id
        assert_includes mention_comment.content, @owner.name
      end

      test "notify_ai_completion skips present users" do
        comment = @creative.comments.create!(
          content: "AI response complete",
          user: @agent,
          topic: @topic
        )

        inbox = Creative.inbox_for(@owner)
        CommentPresenceStore.add(@creative.id, @owner.id)

        assert_no_difference "inbox.comments.count" do
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

        inbox = Creative.inbox_for(@owner)

        assert_no_difference "inbox.comments.count" do
          comment.notify_ai_completion
        end
      end

      test "notify_ai_completion includes long message content in inbox comment" do
        long_content = "A" * 200
        comment = @creative.comments.create!(
          content: long_content,
          user: @agent,
          topic: @topic
        )

        inbox = Creative.inbox_for(@owner)

        assert_difference "inbox.comments.count", 1 do
          comment.notify_ai_completion
        end

        inbox_comment = inbox.comments.where(quoted_comment: comment).last
        assert inbox_comment
        assert_includes inbox_comment.content, long_content
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
