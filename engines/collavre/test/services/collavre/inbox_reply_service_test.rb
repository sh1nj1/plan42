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
      main_topic = @creative.main_topic(fallback_user: @user)
      assert_equal main_topic.id, cross_posted.topic_id, "Topic should be Main topic"
      assert_equal @original_comment.id, cross_posted.quoted_comment_id
    end

    # An inbox cross-post quotes the original comment purely for linkage. It must
    # NOT be treated as a review message: review_message? drives the in-place
    # ReviewHandler flow that OVERWRITES the quoted comment with the agent's
    # reply. When the quoted comment is the agent's own (e.g. it asked a
    # question), that flow would update the question in place instead of posting
    # a new answer. The cross-post must reply normally.
    test "cross-posted reply is not a review message (does not overwrite the quoted comment)" do
      reply = Comment.create!(
        creative: @inbox,
        topic: @system_topic,
        content: "My reply from inbox",
        user: @user,
        skip_dispatch: true
      )

      InboxReplyService.call(reply)

      cross_posted = @creative.comments.where(user: @user, content: "My reply from inbox").last
      assert cross_posted, "Expected cross-posted comment in original creative"
      assert_equal @original_comment.id, cross_posted.quoted_comment_id, "quote linkage preserved"
      assert_not cross_posted.review_message?,
                 "inbox cross-post must reply normally, not trigger the in-place review-update flow"
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

    test "does not cross-post when user lacks feedback permission on original creative" do
      # Use a third user who has no permission on @creative
      third_user = users(:three)
      third_inbox = Creative.inbox_for(third_user)
      third_system_topic = third_inbox.system_topic(fallback_user: third_user)

      # Simulate alarm in third user's inbox
      alarm = Comment.create!(
        creative: third_inbox,
        topic: third_system_topic,
        content: 'Notification about original',
        user: nil,
        skip_default_user: true,
        quoted_comment: @original_comment
      )

      reply = Comment.create!(
        creative: third_inbox,
        topic: third_system_topic,
        content: "Reply from unauthorized user",
        user: third_user,
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
