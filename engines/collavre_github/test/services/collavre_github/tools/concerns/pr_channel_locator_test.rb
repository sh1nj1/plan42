# frozen_string_literal: true

require_relative "../../../../test_helper"

module CollavreGithub
  module Tools
    module Concerns
      # Exercises the locator through a bare host class: pr_monitor and
      # pr_state_set both authorize the topic before reaching these methods, so
      # the creative-less guard is not reachable through either tool's `call`.
      class PrChannelLocatorTest < ActiveSupport::TestCase
        class Host
          include CollavreGithub::Tools::Concerns::PrChannelLocator
          public :parse_pr_url, :lookup_channel, :scoped_creative_ids
        end

        setup do
          @host = Host.new
          @user = users(:one)
          @creative = creatives(:tshirt)
          @topic = Collavre::Topic.create!(name: "T", creative: @creative, user: @user)
        end

        test "downcases the repo and casts the PR number" do
          assert_equal [ "owner/repo", 77 ], @host.parse_pr_url("https://github.com/Owner/Repo/pull/77")
        end

        test "accepts http as well as https" do
          assert_equal [ "owner/repo", 5 ], @host.parse_pr_url("http://github.com/owner/repo/pull/5")
        end

        test "rejects a URL that is not a GitHub PR" do
          assert_raises(ArgumentError) { @host.parse_pr_url("https://github.com/owner/repo/issues/77") }
          assert_raises(ArgumentError) { @host.parse_pr_url("https://example.com/owner/repo/pull/77") }
          assert_raises(ArgumentError) { @host.parse_pr_url(nil) }
        end

        test "finds a channel regardless of the stored repo name's case" do
          channel = GithubPrChannel.create!(
            topic_id: @topic.id,
            config: { "repo_full_name" => "Owner/Repo", "pr_number" => 77 }
          )

          assert_equal channel, @host.lookup_channel(@topic, "owner/repo", 77)
          assert_nil @host.lookup_channel(@topic, "owner/repo", 78)
          assert_nil @host.lookup_channel(@topic, "other/repo", 77)
        end

        test "scopes to the topic's creative and its ancestors" do
          child = Collavre::Creative.create!(user: @user, description: "child", parent: @creative)
          topic = Collavre::Topic.create!(name: "Child T", creative: child, user: @user)

          ids = @host.scoped_creative_ids(topic)

          assert_includes ids, child.id
          assert_includes ids, @creative.id
        end

        test "returns an empty scope when the topic has no creative" do
          @topic.stub(:creative, nil) do
            assert_empty @host.scoped_creative_ids(@topic)
          end
        end
      end
    end
  end
end
