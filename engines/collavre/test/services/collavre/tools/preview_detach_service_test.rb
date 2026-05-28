# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class PreviewDetachServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @topic = Collavre::Topic.create!(name: "Preview T", creative: @creative, user: @user)
        Collavre::Current.user = @user
        @channel = Collavre::PreviewChannel.create!(
          topic_id: @topic.id,
          config: {
            "worktree_id" => "wt-1",
            "preview_url" => "http://localhost:4001",
            "preview_state" => "running"
          }
        )
      end

      teardown do
        Collavre::Current.user = nil
      end

      test "flips preview_state to stopped and detaches the channel" do
        result = PreviewDetachService.new.call(topic_id: @topic.id, worktree_id: "wt-1")
        assert result[:ok]
        assert_equal :stopped, result[:status]
        @channel.reload
        assert_equal "stopped", @channel.preview_state
        assert_predicate @channel, :detached?
      end

      test "keeps the chip visible (not dismissed) so users see the final state" do
        # The PR-channel pattern: post-close chip stays under not_dismissed
        # until the user explicitly hits X. Preview must match so a freshly
        # stopped preview is not silently hidden.
        PreviewDetachService.new.call(topic_id: @topic.id, worktree_id: "wt-1")
        assert_nil @channel.reload.dismissed_at
        assert_includes @topic.channels.not_dismissed.pluck(:id), @channel.id
      end

      test "idempotent on an already stopped+detached channel" do
        PreviewDetachService.new.call(topic_id: @topic.id, worktree_id: "wt-1")
        result = PreviewDetachService.new.call(topic_id: @topic.id, worktree_id: "wt-1")
        assert_equal :noop, result[:status]
      end

      test "noop when no channel exists for the worktree" do
        result = PreviewDetachService.new.call(topic_id: @topic.id, worktree_id: "wt-missing")
        assert result[:ok]
        assert_equal :noop, result[:status]
      end

      test "denies detach when current user lacks write permission" do
        outsider = users(:two)
        Collavre::Current.user = outsider

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          PreviewDetachService.new.call(topic_id: @topic.id, worktree_id: "wt-1")
        end
        assert_equal "running", @channel.reload.preview_state
      end
    end
  end
end
