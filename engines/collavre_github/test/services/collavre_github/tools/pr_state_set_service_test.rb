# frozen_string_literal: true

# Load the engine's test_helper (not the app's) so WebMock + GitHub stubs are
# available for the API-resync tests below.
require_relative "../../../test_helper"

module CollavreGithub
  module Tools
    class PrStateSetServiceTest < ActiveSupport::TestCase
      PR_URL = "https://github.com/owner/repo/pull/77"

      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @topic = Collavre::Topic.create!(name: "T", creative: @creative, user: @user)
        Collavre::Current.user = @user
        @channel = GithubPrChannel.create!(
          topic_id: @topic.id,
          config: { "repo_full_name" => "owner/repo", "pr_number" => 77, "pr_state" => "open" }
        )
      end

      teardown do
        Collavre::Current.user = nil
      end

      def connect_github_account(
        repository_full_name: "owner/repo",
        creative: @creative,
        repository_id: 101,
        remote_repository_id: repository_id
      )
        account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "12345",
          login: "testuser",
          name: "Test User",
          token: "test-token"
        )
        CollavreGithub::RepositoryLink.create!(
          creative: creative,
          github_account: account,
          repository_full_name: repository_full_name,
          repository_id: repository_id
        )
        stub_github_repository(repository_full_name.downcase, id: remote_repository_id) if remote_repository_id
        account
      end

      def stub_pull_request(state:, merged:, repo: "owner/repo", number: 77)
        stub_request(:get, "https://api.github.com/repos/#{repo}/pulls/#{number}")
          .to_return(
            status: 200,
            body: { number: number, state: state, merged: merged }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      # --- explicit state ------------------------------------------------

      test "explicit merged state closes the channel and reports the transition" do
        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "merged")

        assert result[:ok]
        assert_equal @channel.id, result[:channel_id]
        assert_equal "owner/repo", result[:repo]
        assert_equal 77, result[:pr_number]
        assert_equal "merged", result[:pr_state]
        assert_equal "open", result[:previous_state]
        assert_equal "updated", result[:status]
        assert_equal "explicit", result[:state_source]
        assert @channel.reload.detached?
      end

      test "explicit state re-applied is reported as a noop" do
        PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "merged")
        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "merged")

        assert result[:ok]
        assert_equal "noop", result[:status]
      end

      test "explicit open reopens a channel closed by a stale merge" do
        PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "merged")
        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "open")

        assert_equal "open", result[:pr_state]
        assert @channel.reload.active?
      end

      test "rejects a state outside PR_STATES" do
        error = assert_raises(ArgumentError) do
          PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "merged_")
        end
        assert_includes error.message, "merged_"
        assert_equal "open", @channel.reload.pr_state
      end

      # --- GitHub resync -------------------------------------------------

      test "omitting state reads merged from the GitHub API" do
        connect_github_account
        stub_pull_request(state: "closed", merged: true)

        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL)

        assert result[:ok]
        assert_equal "merged", result[:pr_state]
        assert_equal "github", result[:state_source]
        assert_equal "merged", @channel.reload.pr_state
        assert @channel.detached?
      end

      # `merged` is the authoritative flag; `state` reads "closed" for both a
      # merge and an abandonment, so ordering the checks the other way would
      # record every merged PR as closed_without_merge.
      test "a closed but unmerged PR resyncs to closed_without_merge" do
        connect_github_account
        stub_pull_request(state: "closed", merged: false)

        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL)

        assert_equal "closed_without_merge", result[:pr_state]
      end

      test "a still-open PR resyncs to open" do
        connect_github_account
        stub_pull_request(state: "open", merged: false)
        @channel.update!(config: @channel.config.merge("pr_state" => "merged"))
        @channel.detach!

        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL)

        assert_equal "open", result[:pr_state]
        assert @channel.reload.active?
      end

      test "resync matches a RepositoryLink stored in GitHub's canonical case" do
        connect_github_account(repository_full_name: "Owner/Repo")
        stub_pull_request(state: "closed", merged: true)

        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL)

        assert result[:ok]
        assert_equal "merged", result[:pr_state]
      end

      test "resync uses a RepositoryLink on an ancestor creative" do
        child = Collavre::Creative.create!(user: @user, description: "child", parent: @creative)
        topic = Collavre::Topic.create!(name: "Child T", creative: child, user: @user)
        channel = GithubPrChannel.create!(
          topic_id: topic.id,
          config: { "repo_full_name" => "owner/repo", "pr_number" => 77, "pr_state" => "open" }
        )
        connect_github_account
        stub_pull_request(state: "closed", merged: true)

        result = PrStateSetService.new.call(topic_id: topic.id, pr_url: PR_URL)

        assert result[:ok]
        assert_equal "merged", channel.reload.pr_state
      end

      test "resync rejects a reused repository name whose stable id does not match" do
        connect_github_account(repository_id: 111, remote_repository_id: 222)

        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL)

        assert_equal false, result[:ok]
        assert_includes result[:error], "No verified connected GitHub account"
        assert_equal "open", @channel.reload.pr_state
        assert_not_requested :get, "https://api.github.com/repos/owner/repo/pulls/77"
      end

      test "resync tries the next identity-valid account when the first cannot read the PR" do
        child = Collavre::Creative.create!(user: @user, description: "child", parent: @creative)
        topic = Collavre::Topic.create!(name: "Child T", creative: child, user: @user)
        channel = GithubPrChannel.create!(
          topic_id: topic.id,
          config: { "repo_full_name" => "owner/repo", "pr_number" => 77, "pr_state" => "open" }
        )
        first_account = connect_github_account(remote_repository_id: nil)
        second_user = users(:two)
        second_account = CollavreGithub::Account.create!(
          user: second_user,
          github_uid: "67890",
          login: "second-user",
          name: "Second User",
          token: "second-token"
        )
        CollavreGithub::RepositoryLink.create!(
          creative: child,
          github_account: second_account,
          repository_full_name: "owner/repo",
          repository_id: 101
        )
        identity = CollavreGithub::Client::RepositoryIdentity.new(id: 101, full_name: "owner/repo")
        attempts = []
        first_client = Object.new
        first_client.define_singleton_method(:repository_identity) { |_repo| identity }
        first_client.define_singleton_method(:pull_request_details) do |_repo, _number|
          attempts << first_account.id
          nil
        end
        second_client = Object.new
        second_client.define_singleton_method(:repository_identity) { |_repo| identity }
        second_client.define_singleton_method(:pull_request_details) do |_repo, _number|
          attempts << second_account.id
          Struct.new(:merged, :state).new(true, "closed")
        end
        clients = { first_account.id => first_client, second_account.id => second_client }

        result = CollavreGithub::Client.stub(:new, ->(account) { clients.fetch(account.id) }) do
          PrStateSetService.new.call(topic_id: topic.id, pr_url: PR_URL)
        end

        assert result[:ok]
        assert_equal [ first_account.id, second_account.id ], attempts
        assert_equal "merged", channel.reload.pr_state
      end

      test "resync skips an account whose repository identity lookup fails" do
        child = Collavre::Creative.create!(user: @user, description: "child", parent: @creative)
        topic = Collavre::Topic.create!(name: "Child T", creative: child, user: @user)
        channel = GithubPrChannel.create!(
          topic_id: topic.id,
          config: { "repo_full_name" => "owner/repo", "pr_number" => 77, "pr_state" => "open" }
        )
        first_account = connect_github_account(remote_repository_id: nil)
        second_user = users(:two)
        second_account = CollavreGithub::Account.create!(
          user: second_user,
          github_uid: "67890",
          login: "second-user",
          name: "Second User",
          token: "second-token"
        )
        CollavreGithub::RepositoryLink.create!(
          creative: child,
          github_account: second_account,
          repository_full_name: "owner/repo",
          repository_id: 101
        )
        identity = CollavreGithub::Client::RepositoryIdentity.new(id: 101, full_name: "owner/repo")
        first_client = Object.new
        first_client.define_singleton_method(:repository_identity) do |_repo|
          raise Octokit::Unauthorized
        end
        second_client = Object.new
        second_client.define_singleton_method(:repository_identity) { |_repo| identity }
        second_client.define_singleton_method(:pull_request_details) do |_repo, _number|
          Struct.new(:merged, :state).new(true, "closed")
        end
        clients = { first_account.id => first_client, second_account.id => second_client }

        result = CollavreGithub::Client.stub(:new, ->(account) { clients.fetch(account.id) }) do
          PrStateSetService.new.call(topic_id: topic.id, pr_url: PR_URL)
        end

        assert result[:ok]
        assert_equal "merged", channel.reload.pr_state
      end

      test "reports a usable fallback when no GitHub account is connected" do
        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL)

        assert_equal false, result[:ok]
        assert_includes result[:error], "state` explicitly"
        assert_equal "open", @channel.reload.pr_state
      end

      test "reports a usable fallback when the GitHub API call fails" do
        connect_github_account
        stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/77")
          .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL)

        assert_equal false, result[:ok]
        assert_includes result[:error], "state` explicitly"
        assert_equal "open", @channel.reload.pr_state
      end

      # --- lookup and authorization ---------------------------------------

      test "reports no channel when the PR was never attached" do
        result = PrStateSetService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/999",
          state: "merged"
        )

        assert_equal false, result[:ok]
        assert_includes result[:error], "pr_monitor"
      end

      test "matches a legacy channel row stored in mixed case" do
        @channel.update!(config: @channel.config.merge("repo_full_name" => "Owner/Repo"))

        result = PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "merged")

        assert result[:ok]
        assert_equal @channel.id, result[:channel_id]
      end

      test "raises on an invalid PR URL" do
        assert_raises(ArgumentError) do
          PrStateSetService.new.call(topic_id: @topic.id, pr_url: "https://example.com/nope", state: "merged")
        end
      end

      test "denies the change when the current user lacks write permission" do
        Collavre::Current.user = users(:two)

        assert_raises(CollavreGithub::Tools::PermissionDeniedError) do
          PrStateSetService.new.call(topic_id: @topic.id, pr_url: PR_URL, state: "merged")
        end
        assert_equal "open", @channel.reload.pr_state
      end

      test "does not reach a channel attached to a different topic" do
        other_topic = Collavre::Topic.create!(name: "Other", creative: @creative, user: @user)

        result = PrStateSetService.new.call(topic_id: other_topic.id, pr_url: PR_URL, state: "merged")

        assert_equal false, result[:ok]
        assert_equal "open", @channel.reload.pr_state
      end

      # The tool's own authorization gate rejects a creative-less topic before
      # this runs, so the guard is exercised directly rather than through call.
      test "resolves no verified GitHub clients when the topic has no creative scope" do
        service = PrStateSetService.new

        @topic.stub(:creative, nil) do
          assert_empty service.send(:verified_github_clients_for, @topic, "owner/repo")
        end
      end

      test "is registered as an MCP tool named pr_state_set" do
        assert_equal "pr_state_set", PrStateSetService.tool_metadata[:name]
        state_param = PrStateSetService.tool_metadata[:params].find { |p| p[:name] == :state }
        assert_equal false, state_param[:required]
        assert_equal GithubPrChannel::PR_STATES, state_param[:enum]
      end
    end
  end
end
