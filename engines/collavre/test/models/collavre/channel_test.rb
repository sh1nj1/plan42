# frozen_string_literal: true

require "test_helper"

module Collavre
  class ChannelTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Collavre::Current.user = @user
      @creative = Creative.create!(description: "Test Creative", user: @user)
      @topic = Topic.create!(name: "Channel Topic", creative: @creative, user: @user)
    end

    test "belongs to topic and defaults to active state" do
      channel = Channel.new(topic: @topic, type: "Collavre::Channel")
      assert channel.valid?
      assert_predicate channel, :active?
    end

    test "detach! flips state" do
      channel = Channel.create!(topic: @topic, type: "Collavre::Channel")
      channel.detach!
      assert_predicate channel, :detached?
    end

    test "handle raises NotImplementedError on base class" do
      channel = Channel.new(topic: @topic)
      assert_raises(NotImplementedError) { channel.handle(event: "x", payload: {}) }
    end

    test "InjectedMessage holds speaker, message, label, link" do
      msg = Channel::InjectedMessage.new(speaker: @user, message: "hi", label: "PR #1", link: "http://x")
      assert_equal @user, msg.speaker
      assert_equal "PR #1", msg.label
    end

    test "dismiss! sets dismissed_at and detaches when active" do
      channel = Channel.create!(topic: @topic, type: "Collavre::Channel")
      assert_nil channel.dismissed_at
      channel.dismiss!
      assert_predicate channel.reload, :dismissed?
      assert_predicate channel, :detached?
    end

    test "dismiss! on a detached channel only sets dismissed_at" do
      channel = Channel.create!(topic: @topic, type: "Collavre::Channel", state: :detached)
      channel.dismiss!
      assert_predicate channel.reload, :dismissed?
      assert_predicate channel, :detached?
    end

    test "dismiss! is idempotent on already-dismissed channel" do
      channel = Channel.create!(topic: @topic, type: "Collavre::Channel")
      channel.dismiss!
      original_dismissed_at = channel.reload.dismissed_at
      channel.dismiss!
      assert_equal original_dismissed_at, channel.reload.dismissed_at
    end

    test "not_dismissed scope excludes dismissed channels" do
      kept = Channel.create!(topic: @topic, type: "Collavre::Channel")
      gone = Channel.create!(topic: @topic, type: "Collavre::Channel")
      gone.dismiss!
      ids = Channel.not_dismissed.pluck(:id)
      assert_includes ids, kept.id
      refute_includes ids, gone.id
    end
  end
end
