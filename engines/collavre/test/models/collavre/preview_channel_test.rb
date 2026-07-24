# frozen_string_literal: true

require "test_helper"

module Collavre
  class PreviewChannelTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Collavre::Current.user = @user
      @creative = Creative.create!(description: "Preview Creative", user: @user)
      @topic = Topic.create!(name: "Preview Topic", creative: @creative, user: @user)
      @channel = PreviewChannel.create!(
        topic: @topic,
        config: {
          "worktree_id" => "wt-123",
          "preview_url" => "http://localhost:4001",
          "preview_state" => "running"
        }
      )
    end

    test "default_label falls back to localized 'Preview' when no custom label" do
      assert_equal I18n.t("collavre.channel.preview.label_default"), @channel.default_label
    end

    test "default_label prefers custom label from config" do
      @channel.update!(config: @channel.config.merge("label" => "Preview #42"))
      assert_equal "Preview #42", @channel.default_label
    end

    test "default_link returns preview_url" do
      assert_equal "http://localhost:4001", @channel.default_link
    end

    test "badge_state defaults to running when config has no preview_state" do
      fresh = PreviewChannel.create!(
        topic: @topic,
        config: { "worktree_id" => "wt-fresh", "preview_url" => "http://localhost:4002" }
      )
      assert_equal "running", fresh.badge_state
    end

    test "preview_state= rejects values outside PREVIEW_STATES" do
      assert_raises(ArgumentError) { @channel.preview_state = "paused" }
      assert_raises(ArgumentError) { @channel.preview_state = "" }
      assert_raises(ArgumentError) { @channel.preview_state = nil }
      assert_equal "running", @channel.preview_state
    end

    test "preview_state= persists each whitelisted value" do
      PreviewChannel::PREVIEW_STATES.each do |s|
        @channel.preview_state = s
        @channel.save!
        assert_equal s, @channel.reload.preview_state
      end
    end

    test "badge_title returns localized string for each state" do
      @channel.preview_state = "running"
      assert_equal I18n.t("collavre.channel.preview.badge.running"), @channel.badge_title
      @channel.preview_state = "stopped"
      assert_equal I18n.t("collavre.channel.preview.badge.stopped"), @channel.badge_title
    end

    test "handle is a no-op — preview channels have no external event source" do
      assert_nil @channel.handle(event: "anything", payload: {})
    end

    test "attached_message embeds label and url, authored by the channel bot" do
      msg = @channel.attached_message
      assert_kind_of Collavre::Channel::InjectedMessage, msg
      assert_equal Collavre::Channel::BOT_EMAIL, msg.speaker.email
      assert_includes msg.message, "http://localhost:4001"
      assert_equal "http://localhost:4001", msg.link
    end
  end
end
