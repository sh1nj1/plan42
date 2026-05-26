require_relative "../../test_helper"

module CollavreGithub
  class WebhooksControllerChannelsTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @account = CollavreGithub::Account.create!(
        user: @user,
        github_uid: "12345",
        login: "testuser",
        name: "Test",
        token: "test-token"
      )
      @link = CollavreGithub::RepositoryLink.create!(
        creative: @creative,
        github_account: @account,
        repository_full_name: "owner/repo"
      )
      @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "T")
      @channel = GithubPrChannel.create!(
        topic: @topic,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 99 }
      )
    end

    test "issue_comment.created on monitored PR injects a comment into the topic" do
      payload = {
        action: "created",
        comment: {
          id: 1,
          body: "fix typo",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json

      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "issue_comment",
            "X-Hub-Signature-256" => sig
          }
      end
      assert_response :ok
    end

    test "per-channel handle failure does not block sibling channels on same PR" do
      # Two extra channels on the same PR. One raises in #handle, the other is healthy.
      # The healthy one must still receive the injection — the failing channel must
      # not poison the dispatch loop.
      broken_class = Class.new(GithubPrChannel) do
        def handle(event:, payload:)
          raise "boom"
        end
      end
      CollavreGithub.const_set(:BrokenTestChannel, broken_class)
      broken_topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Broken")
      sibling_topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Sibling")
      CollavreGithub::BrokenTestChannel.create!(
        topic: broken_topic,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 99 }
      )
      GithubPrChannel.create!(
        topic: sibling_topic,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 99 }
      )

      payload = {
        action: "created",
        comment: {
          id: 7,
          body: "isolation check",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      before_sibling = Collavre::Comment.where(topic_id: sibling_topic.id).count
      before_original = Collavre::Comment.where(topic_id: @topic.id).count

      post "/github/webhook",
        params: payload,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "issue_comment",
          "X-Hub-Signature-256" => sig
        }

      assert_response :ok
      assert_equal before_sibling + 1, Collavre::Comment.where(topic_id: sibling_topic.id).count,
        "healthy sibling channel should still inject"
      assert_equal before_original + 1, Collavre::Comment.where(topic_id: @topic.id).count,
        "original healthy channel should still inject"
      assert_equal 0, Collavre::Comment.where(topic_id: broken_topic.id).count,
        "broken channel should not inject"
    ensure
      if CollavreGithub.const_defined?(:BrokenTestChannel)
        CollavreGithub.send(:remove_const, :BrokenTestChannel)
      end
    end

    test "dispatch matches channels case-insensitively against repo_full_name" do
      # Legacy channel rows may have stored mixed-case repo names (created
      # before normalization landed). Webhook payloads always carry the
      # canonical lowercase value; comparison must be case-insensitive so
      # those rows still receive events.
      legacy_topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Legacy")
      GithubPrChannel.create!(
        topic: legacy_topic,
        config: { "repo_full_name" => @link.repository_full_name.upcase, "pr_number" => 99 }
      )

      payload = {
        action: "created",
        comment: {
          id: 42,
          body: "case insensitive",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { Collavre::Comment.where(topic_id: legacy_topic.id).count }, 1 do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "issue_comment",
            "X-Hub-Signature-256" => sig
          }
      end
      assert_response :ok
    end

    test "pull_request.closed injects closing comment AND detaches channel" do
      payload = {
        action: "closed",
        pull_request: {
          number: 99,
          merged: true,
          html_url: "https://github.com/#{@link.repository_full_name}/pull/99"
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request",
            "X-Hub-Signature-256" => sig
          }
      end
      assert_response :ok
      assert_predicate @channel.reload, :detached?
    end
  end
end
