# frozen_string_literal: true

require "test_helper"

module Collavre
  class AgentChannelTest < ActionCable::Channel::TestCase
    tests Collavre::AgentChannel

    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @topic = @creative.topics.create!(name: "Agent Test Topic", user: @user)
    end

    test "subscribes successfully with valid topic and permission" do
      stub_connection current_user: @user
      subscribe topic_id: @topic.id

      assert subscription.confirmed?
      assert_has_stream "agent:topic:#{@topic.id}"
    end

    test "rejects subscription without topic_id" do
      stub_connection current_user: @user
      subscribe

      assert subscription.rejected?
    end

    test "rejects subscription without authentication" do
      stub_connection current_user: nil
      subscribe topic_id: @topic.id

      assert subscription.rejected?
    end

    test "rejects subscription for non-existent topic" do
      stub_connection current_user: @user
      subscribe topic_id: 999_999

      assert subscription.rejected?
    end

    test "rejects subscription when user lacks read permission" do
      other_user = users(:two)
      stub_connection current_user: other_user
      subscribe topic_id: @topic.id

      assert subscription.rejected?
    end

    test "broadcast_comment sends correct payload" do
      comment = @creative.comments.create!(
        content: "Test broadcast",
        user: @user,
        topic: @topic
      )

      assert_broadcast_on("agent:topic:#{@topic.id}", {
        type: "comment",
        comment: {
          id: comment.id,
          content: "Test broadcast",
          author_id: @user.id,
          author_name: @user.display_name,
          topic_id: @topic.id,
          creative_id: @creative.id,
          created_at: comment.created_at.iso8601
        }
      }) do
        AgentChannel.broadcast_comment(@topic.id, comment)
      end
    end
  end
end
