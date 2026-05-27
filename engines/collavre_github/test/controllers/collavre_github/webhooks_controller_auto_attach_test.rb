require_relative "../../test_helper"

module CollavreGithub
  class WebhooksControllerAutoAttachTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @account = CollavreGithub::Account.create!(
        user: @user, github_uid: "12345", login: "testuser",
        name: "Test", token: "test-token"
      )
      @link = CollavreGithub::RepositoryLink.create!(
        creative: @creative, github_account: @account,
        repository_full_name: "owner/repo"
      )
      @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "T")
    end

    test "pull_request.opened with topic link in body creates a channel" do
      payload = {
        action: "opened",
        pull_request: {
          number: 555,
          html_url: "https://github.com/#{@link.repository_full_name}/pull/555",
          body: "Linked topic: /creatives/#{@creative.id}/topics/#{@topic.id}"
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json

      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { GithubPrChannel.count }, 1 do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request",
            "X-Hub-Signature-256" => sig
          }
      end
      channel = GithubPrChannel.last
      assert_equal @topic.id, channel.topic_id
      assert_equal 555, channel.pr_number
      assert_equal @link.repository_full_name, channel.repo_full_name
    end

    test "pull_request.opened without topic link does not create a channel" do
      payload = {
        action: "opened",
        pull_request: { number: 556, body: "no topic link here" },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { GithubPrChannel.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
    end

    test "pull_request.opened ignores topic link pointing to a creative not linked to this repo" do
      # An attacker opens a PR on owner/repo, but puts a foreign tenant's
      # topic link in the description. We must NOT auto-attach.
      foreign_creative = creatives(:childless_creative)
      foreign_topic = Collavre::Topic.create!(creative: foreign_creative, user: @user, name: "Foreign")

      payload = {
        action: "opened",
        pull_request: {
          number: 557,
          body: "Linked topic: /creatives/#{foreign_creative.id}/topics/#{foreign_topic.id}"
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { GithubPrChannel.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
    end

    test "pull_request.opened with topic on a child creative auto-attaches (subtree inherits link)" do
      child = Collavre::Creative.create!(parent: @creative, user: @user, description: "child")
      child_topic = Collavre::Topic.create!(creative: child, user: @user, name: "Child T")

      payload = {
        action: "opened",
        pull_request: {
          number: 560,
          body: "Linked topic: /creatives/#{child.id}/topics/#{child_topic.id}"
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { GithubPrChannel.count }, 1 do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
      channel = GithubPrChannel.last
      assert_equal child_topic.id, channel.topic_id
    end

    test "pull_request.opened reactivates a detached channel" do
      detached = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 558 },
        state: :detached
      )

      payload = {
        action: "opened",
        pull_request: {
          number: 558,
          body: "Linked topic: /creatives/#{@creative.id}/topics/#{@topic.id}"
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { GithubPrChannel.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
      assert detached.reload.active?
    end

    test "pull_request.reopened reactivates a dismissed+detached channel and resets pr_state" do
      # User dismissed the chip after merge; later the PR is reopened on GitHub.
      # GitHub fires `pull_request.reopened` (NOT `opened`), so the auto-attach
      # guard must accept reopened to clear dismissed_at and flip state back to
      # active — otherwise dispatch_to_channels (.active scope) skips the row
      # and the chip stays hidden for the lifetime of the reopened PR.
      dismissed = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: {
          "repo_full_name" => @link.repository_full_name,
          "pr_number" => 561,
          "pr_state" => "merged"
        },
        state: :detached,
        dismissed_at: 1.day.ago
      )

      payload = {
        action: "reopened",
        pull_request: {
          number: 561,
          body: "Linked topic: /creatives/#{@creative.id}/topics/#{@topic.id}"
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { GithubPrChannel.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
      dismissed.reload
      assert dismissed.active?
      assert_nil dismissed.dismissed_at
      assert_equal "open", dismissed.pr_state
    end

    test "channels table rejects duplicate (type, topic, repo, pr) at DB level" do
      GithubPrChannel.create!(
        topic_id: @topic.id,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 559 }
      )
      assert_raises(ActiveRecord::RecordNotUnique) do
        GithubPrChannel.create!(
          topic_id: @topic.id,
          config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 559 }
        )
      end
    end
  end
end
