# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentAgentBroadcastTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @topic = @creative.topics.create!(name: "Broadcast Test", user: @user)
      Current.session = OpenStruct.new(user: @user)
    end

    teardown do
      Current.reset
    end

    test "broadcasts to agent channel on comment create" do
      broadcast_called = false
      original_method = AgentChannel.method(:broadcast_comment)

      AgentChannel.stub(:broadcast_comment, ->(topic_id, comment) {
        broadcast_called = true
        assert_equal @topic.id, topic_id
        assert_equal "Hello agent", comment.content
      }) do
        @creative.comments.create!(
          content: "Hello agent",
          user: @user,
          topic: @topic
        )
      end

      assert broadcast_called, "AgentChannel.broadcast_comment should have been called"
    end

    test "does not broadcast when comment has no topic" do
      broadcast_called = false

      AgentChannel.stub(:broadcast_comment, ->(*_args) {
        broadcast_called = true
      }) do
        @creative.comments.create!(
          content: "No topic comment",
          user: @user
        )
      end

      refute broadcast_called, "Should not broadcast comment without topic_id"
    end

    test "does not broadcast private comments" do
      broadcast_called = false

      AgentChannel.stub(:broadcast_comment, ->(*_args) {
        broadcast_called = true
      }) do
        @creative.comments.create!(
          content: "Private message",
          user: @user,
          topic: @topic,
          private: true
        )
      end

      refute broadcast_called, "Should not broadcast private comments"
    end
  end
end
