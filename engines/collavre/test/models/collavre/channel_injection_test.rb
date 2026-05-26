# frozen_string_literal: true

require "test_helper"

module Collavre
  class ChannelInjectionTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Collavre::Current.user = @user

      @creative = Creative.create!(description: "Test Creative", user: @user)
      @topic = Topic.create!(name: "Channel Topic", creative: @creative, user: @user)
      @channel = Channel.create!(topic: @topic, type: "Collavre::Channel")
      @bot = User.find_by!(email: "channel@collavre.local")
      @msg = Channel::InjectedMessage.new(
        speaker: @bot,
        message: "hello from PR",
        label: "PR #42",
        link: "https://github.com/owner/repo/pull/42"
      )
    end

    test "inject_into_topic! creates a comment authored by the speaker" do
      assert_difference -> { Comment.where(creative_id: @creative.id).count }, 1 do
        @channel.inject_into_topic!(@msg)
      end
      comment = Comment.where(creative_id: @creative.id).last
      assert_equal "hello from PR", comment.content
      assert_equal "channel@collavre.local", comment.user.email
      assert_equal @topic.id, comment.topic_id
      assert_equal @creative.id, comment.creative_id
    end

    test "inject_into_topic! caches label and link on channel" do
      @channel.inject_into_topic!(@msg)
      @channel.reload
      assert_equal "PR #42", @channel.latest_label
      assert_equal "https://github.com/owner/repo/pull/42", @channel.latest_link
      assert_not_nil @channel.last_event_at
    end
  end
end
