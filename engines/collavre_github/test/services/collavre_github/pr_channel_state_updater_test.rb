# frozen_string_literal: true

require_relative "../../test_helper"

module CollavreGithub
  class PrChannelStateUpdaterTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @topic = Collavre::Topic.create!(name: "T", creative: @creative, user: @user)
      @channel = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: { "repo_full_name" => "owner/repo", "pr_number" => 77, "pr_state" => "open" }
      )
    end

    test "merged: sets state, injects the closing message and detaches" do
      assert_difference -> { @creative.comments.count }, 1 do
        result = PrChannelStateUpdater.call(channel: @channel, state: "merged")
        assert_equal :updated, result.status
        assert_equal "open", result.previous_state
      end

      @channel.reload
      assert_equal "merged", @channel.pr_state
      assert @channel.detached?
      comment = @creative.comments.order(:created_at).last
      assert_equal @topic.id, comment.topic_id
      assert_includes comment.content, "PR #77"
    end

    test "closed_without_merge posts the closed verb, not the merged one" do
      PrChannelStateUpdater.call(channel: @channel, state: "closed_without_merge")

      assert_equal "closed_without_merge", @channel.reload.pr_state
      content = @creative.comments.order(:created_at).last.content
      assert_includes content, I18n.t("collavre_github.channel.pr.state_closed")
      assert_not_includes content, I18n.t("collavre_github.channel.pr.state_merged")
    end

    test "closing message is identical to the one the webhook would have posted" do
      webhook_channel = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: { "repo_full_name" => "owner/repo", "pr_number" => 78, "pr_state" => "open" }
      )
      webhook_message = webhook_channel.send(
        :handle_pull_request,
        "action" => "closed",
        "pull_request" => { "merged" => true }
      )

      PrChannelStateUpdater.call(channel: @channel, state: "merged")
      manual_content = @creative.comments.order(:created_at).last.content

      assert_equal webhook_message.message.sub("PR #78", "PR #77"), manual_content
    end

    test "reopening a merged channel reactivates it and resumes monitoring" do
      PrChannelStateUpdater.call(channel: @channel, state: "merged")

      assert_difference -> { @creative.comments.count }, 1 do
        result = PrChannelStateUpdater.call(channel: @channel, state: "open")
        assert_equal :updated, result.status
        assert_equal "merged", result.previous_state
      end

      @channel.reload
      assert_equal "open", @channel.pr_state
      assert @channel.active?
      assert_includes @creative.comments.order(:created_at).last.content, "PR #77"
    end

    test "reopening clears dismissed_at so the chip resurfaces" do
      @channel.dismiss!
      assert @channel.reload.dismissed?

      PrChannelStateUpdater.call(channel: @channel, state: "open")

      @channel.reload
      assert_nil @channel.dismissed_at
      assert @channel.active?
    end

    test "repeating a close is a noop and injects no second message" do
      PrChannelStateUpdater.call(channel: @channel, state: "merged")

      assert_no_difference -> { @creative.comments.count } do
        result = PrChannelStateUpdater.call(channel: @channel, state: "merged")
        assert_equal :noop, result.status
        assert_equal "merged", result.previous_state
      end
    end

    test "repeating open on an active channel is a noop" do
      assert_no_difference -> { @creative.comments.count } do
        assert_equal :noop, PrChannelStateUpdater.call(channel: @channel, state: "open").status
      end
    end

    # A channel can read "open" while sitting detached — the user dismissed the
    # chip, or a reopen event was missed. Matching state alone must not be read
    # as "already settled" or the reactivation half never runs.
    test "open on a detached but open-state channel still reactivates" do
      @channel.detach!

      assert_difference -> { @creative.comments.count }, 1 do
        assert_equal :updated, PrChannelStateUpdater.call(channel: @channel, state: "open").status
      end
      assert @channel.reload.active?
    end

    test "merged on an already-merged but still active channel completes the detach" do
      @channel.update!(config: @channel.config.merge("pr_state" => "merged"))
      assert @channel.active?

      assert_equal :updated, PrChannelStateUpdater.call(channel: @channel, state: "merged").status
      assert @channel.reload.detached?
    end

    # Closing a channel the user already dismissed still has to record the
    # merge — the badge is what a later reattach reads to decide its color.
    test "merging an already-detached open channel records the state without a second detach" do
      @channel.detach!

      assert_difference -> { @creative.comments.count }, 1 do
        assert_equal :updated, PrChannelStateUpdater.call(channel: @channel, state: "merged").status
      end

      @channel.reload
      assert_equal "merged", @channel.pr_state
      assert @channel.detached?
    end

    test "rejects a state outside PR_STATES before touching the channel" do
      assert_raises(ArgumentError) do
        PrChannelStateUpdater.call(channel: @channel, state: "merged_")
      end
      assert_equal "open", @channel.reload.pr_state
    end

    test "a failed injection rolls the state change back" do
      @channel.stub(:inject_into_topic!, ->(_msg) { raise "boom" }) do
        assert_raises(RuntimeError) do
          PrChannelStateUpdater.call(channel: @channel, state: "merged")
        end
      end

      @channel.reload
      assert_equal "open", @channel.pr_state
      assert @channel.active?
    end
  end
end
