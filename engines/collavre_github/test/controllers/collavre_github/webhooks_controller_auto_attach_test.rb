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

    test "pull_request.opened redelivery does NOT reactivate a detached channel" do
      # A `pull_request.opened` redelivery (GitHub retries on 5xx or duplicate
      # fan-out) must not undo a prior detach. Only `reopened` reflects an
      # actual lifecycle change on the GitHub side.
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
      assert detached.reload.detached?
    end

    test "pull_request.opened redelivery does NOT undo a dismissed chip" do
      # User clicks X on an open PR's chip → dismiss! sets dismissed_at and
      # flips state to detached. A subsequent `opened` redelivery from GitHub
      # must leave the dismissal intact (no dismissed_at clear, no reactivate,
      # no announce). Only `reopened` is allowed to resurrect a dismissed chip.
      dismissed = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 563, "pr_state" => "open" },
        state: :detached,
        dismissed_at: 1.hour.ago
      )
      original_dismissed_at = dismissed.dismissed_at
      payload = {
        action: "opened",
        pull_request: { number: 563, body: "Linked topic: /creatives/#{@creative.id}/topics/#{@topic.id}" },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { @topic.comments.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
      dismissed.reload
      assert dismissed.detached?
      assert_equal original_dismissed_at.to_i, dismissed.dismissed_at.to_i
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

      # PR events also feed the creative system-comment stream, so the reopen
      # webhook produces 2 new comments: the feed event + the channel-scoped
      # reopen announcement. The announcement is the one we care about here.
      assert_difference -> { @topic.comments.count }, 1 do
        assert_no_difference -> { GithubPrChannel.count } do
          post "/github/webhook", params: payload,
            headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
        end
      end
      dismissed.reload
      assert dismissed.active?
      assert_nil dismissed.dismissed_at
      assert_equal "open", dismissed.pr_state
      # User saw the chip silently reappear before this; verify the lifecycle
      # is now traceable via a one-line announcement comment in the topic.
      last = @topic.comments.order(:created_at).last
      assert_match(/reopened|재오픈/i, last.content)
    end

    test "pull_request.opened reactivation of an already-active channel does NOT re-announce" do
      # Idempotent webhook redelivery of `opened` shouldn't spam the topic
      # with a reopen announcement (the creative feed comment is separate).
      active = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 562, "pr_state" => "open" }
      )
      payload = {
        action: "opened",
        pull_request: { number: 562, body: "Linked topic: /creatives/#{@creative.id}/topics/#{@topic.id}" },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { @topic.comments.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
      assert active.reload.active?
    end

    test "pull_request.reopened reactivation runs inside with_lock so concurrent deliveries cannot double-announce" do
      # Regression: without a row lock + re-read inside, two concurrent reopened
      # webhook deliveries for the same dismissed/detached channel both observe
      # was_inactive=true and both inject the reopened announcement. The fix
      # wraps the reactivation block in `existing.with_lock`; this test asserts
      # the lock is acquired before any state mutation / inject so that the
      # contract is captured by tests, not just by inspection.
      dismissed = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: {
          "repo_full_name" => @link.repository_full_name,
          "pr_number" => 563,
          "pr_state" => "merged"
        },
        state: :detached,
        dismissed_at: 1.day.ago
      )

      lock_acquired = false
      original_with_lock = GithubPrChannel.instance_method(:with_lock)
      GithubPrChannel.define_method(:with_lock) do |*args, &block|
        lock_acquired = true if id == dismissed.id
        original_with_lock.bind(self).call(*args, &block)
      end

      begin
        payload = {
          action: "reopened",
          pull_request: {
            number: 563,
            body: "Linked topic: /creatives/#{@creative.id}/topics/#{@topic.id}"
          },
          repository: { full_name: @link.repository_full_name }
        }.to_json
        sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      ensure
        GithubPrChannel.define_method(:with_lock, original_with_lock)
      end

      assert lock_acquired, "expected reactivation path to acquire row lock on the dismissed channel"
      dismissed.reload
      assert dismissed.active?
      assert_nil dismissed.dismissed_at
    end

    test "pull_request.reopened without topic link in PR body still reactivates an existing manually-attached channel" do
      # Channels created via `pr_monitor` MCP tool (manual attach) have a valid
      # GithubPrChannel row but the PR description never had a topic link. When
      # the PR is later reopened, GitHub's webhook payload has no topic link in
      # body. Without this regression path, `maybe_auto_attach_channel` would
      # short-circuit at the PrTopicLinkParser gate and never reactivate the
      # existing dismissed/detached row; dispatch_to_channels (.active scope)
      # would then skip the chip and the PR would go unmonitored after reopen.
      dismissed = GithubPrChannel.create!(
        topic_id: @topic.id,
        config: {
          "repo_full_name" => @link.repository_full_name,
          "pr_number" => 570,
          "pr_state" => "closed_without_merge"
        },
        state: :detached,
        dismissed_at: 2.hours.ago
      )

      payload = {
        action: "reopened",
        pull_request: { number: 570, body: "no topic link in this PR body" },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { @topic.comments.count }, 1 do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
      dismissed.reload
      assert dismissed.active?
      assert_nil dismissed.dismissed_at
      assert_equal "open", dismissed.pr_state
      last = @topic.comments.order(:created_at).last
      assert_match(/reopened|재오픈/i, last.content)
    end

    test "pull_request.reopened does NOT reactivate channel whose creative no longer has the repo link" do
      # If the RepositoryLink for this repo was removed (or the channel's topic
      # was moved to a creative subtree outside the link scope), the reopen
      # webhook must not resurrect a stale monitor for a different tenant.
      foreign_creative = creatives(:childless_creative)
      foreign_topic = Collavre::Topic.create!(creative: foreign_creative, user: @user, name: "Foreign")
      stale = GithubPrChannel.create!(
        topic_id: foreign_topic.id,
        config: {
          "repo_full_name" => @link.repository_full_name,
          "pr_number" => 571,
          "pr_state" => "merged"
        },
        state: :detached,
        dismissed_at: 1.hour.ago
      )

      payload = {
        action: "reopened",
        pull_request: { number: 571, body: "no link" },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { foreign_topic.comments.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
      stale.reload
      assert stale.detached?
      assert_not_nil stale.dismissed_at
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
