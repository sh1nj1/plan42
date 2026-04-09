require "test_helper"

module Collavre
  class InboxReplyServiceTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @other_user = users(:two)
      @creative = creatives(:tshirt)

      # Ensure presence cache is clear so notifications fire
      Rails.cache.delete(CommentPresenceStore.key(@creative.id))

      # Create a comment on the creative that triggers an inbox notification
      @original_comment = Comment.create!(
        creative: @creative,
        user: @other_user,
        content: "Original message",
        skip_dispatch: true
      )

      # Set up inbox with system topic
      @inbox = Creative.inbox_for(@user)
      @system_topic = @inbox.system_topic(fallback_user: @user)

      # Simulate a notification alarm (system message with quoted_comment)
      @alarm = Comment.create!(
        creative: @inbox,
        topic: @system_topic,
        content: 'Test User added "Original message" to "T-Shirt".',
        user: nil,
        skip_default_user: true,
        quoted_comment: @original_comment
      )
    end

    test "cross-posts reply to original creative and topic" do
      reply = Comment.create!(
        creative: @inbox,
        topic: @system_topic,
        content: "My reply from inbox",
        user: @user,
        skip_dispatch: true
      )

      assert_difference("Comment.count", 1) do
        InboxReplyService.call(reply)
      end

      cross_posted = @creative.comments.where(user: @user, content: "My reply from inbox").last
      assert cross_posted, "Expected cross-posted comment in original creative"
      assert_nil cross_posted.topic_id, "Topic should match original (nil)"
      assert_equal @original_comment.id, cross_posted.quoted_comment_id
    end

    test "does not cross-post for non-inbox creatives" do
      reply = Comment.create!(
        creative: @creative,
        content: "Normal comment",
        user: @user,
        skip_dispatch: true
      )

      assert_no_difference("Comment.count") do
        InboxReplyService.call(reply)
      end
    end

    test "does not cross-post for non-System topic" do
      other_topic = @inbox.topics.create!(name: "Other", user: @user)
      reply = Comment.create!(
        creative: @inbox,
        topic: other_topic,
        content: "Not a system topic reply",
        user: @user,
        skip_dispatch: true
      )

      assert_no_difference("Comment.count") do
        InboxReplyService.call(reply)
      end
    end

    test "does not cross-post when no alarm exists" do
      # Remove all system messages (including auto-created notifications)
      @inbox.comments.where(topic: @system_topic, user_id: nil).destroy_all

      reply = Comment.create!(
        creative: @inbox,
        topic: @system_topic,
        content: "Reply with no alarm",
        user: @user,
        skip_dispatch: true
      )

      assert_no_difference("Comment.count") do
        InboxReplyService.call(reply)
      end
    end

    test "does not cross-post when alarm has no quoted_comment" do
      @alarm.update!(quoted_comment: nil)

      reply = Comment.create!(
        creative: @inbox,
        topic: @system_topic,
        content: "Reply to alarm without quote",
        user: @user,
        skip_dispatch: true
      )

      assert_no_difference("Comment.count") do
        InboxReplyService.call(reply)
      end
    end
  end
end
