# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class PreviewAttachServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @topic = Collavre::Topic.create!(name: "Preview T", creative: @creative, user: @user)
        Collavre::Current.user = @user
      end

      teardown do
        Collavre::Current.user = nil
      end

      test "creates a PreviewChannel for the topic and seeds chip label/link" do
        result = PreviewAttachService.new.call(
          topic_id: @topic.id,
          preview_url: "http://localhost:4001",
          worktree_id: "wt-1"
        )
        assert result[:ok]
        assert_equal :created, result[:status]
        channel = Collavre::PreviewChannel.find(result[:channel_id])
        assert_equal @topic.id, channel.topic_id
        assert_equal "wt-1", channel.worktree_id
        assert_equal "http://localhost:4001", channel.preview_url
        # Announcement caches latest_label/latest_link so chip is clickable
        # immediately, mirroring the PR-channel first-attach behavior.
        assert_equal "http://localhost:4001", channel.latest_link
      end

      test "first attach injects exactly one announcement comment" do
        assert_difference -> { @creative.comments.count }, 1 do
          PreviewAttachService.new.call(
            topic_id: @topic.id,
            preview_url: "http://localhost:4001",
            worktree_id: "wt-1"
          )
        end
      end

      test "idempotent: same (topic, worktree_id) does not duplicate channel or re-announce" do
        2.times do
          PreviewAttachService.new.call(
            topic_id: @topic.id,
            preview_url: "http://localhost:4001",
            worktree_id: "wt-1"
          )
        end
        assert_equal 1, Collavre::PreviewChannel.where(topic_id: @topic.id).count

        assert_no_difference -> { @creative.comments.count } do
          PreviewAttachService.new.call(
            topic_id: @topic.id,
            preview_url: "http://localhost:4001",
            worktree_id: "wt-1"
          )
        end
      end

      test "different worktree_id on same topic creates a separate chip" do
        PreviewAttachService.new.call(
          topic_id: @topic.id,
          preview_url: "http://localhost:4001",
          worktree_id: "wt-1"
        )
        PreviewAttachService.new.call(
          topic_id: @topic.id,
          preview_url: "http://localhost:4002",
          worktree_id: "wt-2"
        )
        assert_equal 2, Collavre::PreviewChannel.where(topic_id: @topic.id).count
      end

      test "reactivates a stopped+detached channel, refreshes URL, and re-announces" do
        existing = Collavre::PreviewChannel.create!(
          topic_id: @topic.id,
          config: {
            "worktree_id" => "wt-1",
            "preview_url" => "http://localhost:4001",
            "preview_state" => "stopped"
          },
          state: :detached,
          dismissed_at: 1.hour.ago
        )

        assert_difference -> { @creative.comments.count }, 1 do
          PreviewAttachService.new.call(
            topic_id: @topic.id,
            # Port changed after restart — reattach must adopt the new URL,
            # otherwise the chip link points at a dead server.
            preview_url: "http://localhost:4099",
            worktree_id: "wt-1"
          )
        end

        existing.reload
        assert_predicate existing, :active?
        assert_nil existing.dismissed_at
        assert_equal "running", existing.preview_state
        assert_equal "http://localhost:4099", existing.preview_url
      end

      test "denies attach when current user lacks write permission on the topic creative" do
        outsider = users(:two)
        Collavre::Current.user = outsider

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          PreviewAttachService.new.call(
            topic_id: @topic.id,
            preview_url: "http://localhost:4001",
            worktree_id: "wt-1"
          )
        end
        assert_equal 0, Collavre::PreviewChannel.where(topic_id: @topic.id).count
      end

      test "custom label is persisted and surfaces in the chip" do
        result = PreviewAttachService.new.call(
          topic_id: @topic.id,
          preview_url: "http://localhost:4001",
          worktree_id: "wt-1",
          label: "Preview #42"
        )
        channel = Collavre::PreviewChannel.find(result[:channel_id])
        assert_equal "Preview #42", channel.default_label
      end
    end
  end
end
