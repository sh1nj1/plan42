# frozen_string_literal: true

require "test_helper"

module CollavreGithub
  module Tools
    class PrMonitorServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @topic = Collavre::Topic.create!(name: "T", creative: @creative, user: @user)
      end

      test "attaches a GithubPrChannel for given topic and PR URL" do
        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )
        assert result[:ok]
        channel = GithubPrChannel.last
        assert_equal @topic.id, channel.topic_id
        assert_equal "owner/repo", channel.repo_full_name
        assert_equal 77, channel.pr_number
      end

      test "idempotent: calling twice does not create duplicate" do
        2.times do
          PrMonitorService.new.call(topic_id: @topic.id, pr_url: "https://github.com/owner/repo/pull/77")
        end
        assert_equal 1, GithubPrChannel.where(topic_id: @topic.id).count
      end

      test "raises on invalid PR URL" do
        assert_raises(ArgumentError) do
          PrMonitorService.new.call(topic_id: @topic.id, pr_url: "https://example.com/not-a-pr")
        end
      end

      test "normalizes mixed-case repo names to lowercase so webhooks match" do
        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/Owner/Repo/pull/88"
        )
        assert result[:ok]
        channel = GithubPrChannel.find(result[:channel_id])
        assert_equal "owner/repo", channel.repo_full_name
      end

      test "reuses channel when input casing differs from stored row" do
        first = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/99"
        )
        second = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/OWNER/REPO/pull/99"
        )
        assert_equal first[:channel_id], second[:channel_id]
        assert_equal 1, GithubPrChannel.where(topic_id: @topic.id).count
      end

      test "reactivates a detached channel instead of orphaning it" do
        channel = GithubPrChannel.create!(
          topic_id: @topic.id,
          config: { "repo_full_name" => "owner/repo", "pr_number" => 77 },
          state: :detached
        )

        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )

        assert result[:ok]
        assert_equal channel.id, result[:channel_id]
        assert channel.reload.active?
      end
    end
  end
end
