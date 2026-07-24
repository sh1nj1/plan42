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

    test "skips dispatch when channel's creative is no longer in the repo's link scope" do
      # Channel was attached when the link existed. After the link is removed
      # (or the topic moves to an unrelated creative subtree), the channel must
      # NOT receive further events from the original repo — otherwise external
      # PR comments would keep leaking into a tenant that no longer owns the
      # repo. Build the scenario by attaching to an unrelated creative.
      outside_user = users(:two)
      outside_creative = Collavre::Creative.create!(user: outside_user, description: "outside")
      outside_topic = Collavre::Topic.create!(creative: outside_creative, user: outside_user, name: "Outside")
      outside_channel = GithubPrChannel.create!(
        topic: outside_topic,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 99 }
      )

      payload = {
        action: "created",
        comment: {
          id: 11,
          body: "should not leak",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      before_outside = Collavre::Comment.where(topic_id: outside_topic.id).count
      before_inside = Collavre::Comment.where(topic_id: @topic.id).count

      post "/github/webhook",
        params: payload,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "issue_comment",
          "X-Hub-Signature-256" => sig
        }

      assert_response :ok
      assert_equal before_outside, Collavre::Comment.where(topic_id: outside_topic.id).count,
        "out-of-scope channel must not receive injected message"
      assert_equal before_inside + 1, Collavre::Comment.where(topic_id: @topic.id).count,
        "in-scope channel still receives injected message"
      assert outside_channel.reload.active?, "channel state remains untouched (only dispatch is skipped)"
    end

    test "case-mismatched repository.full_name still uses repo-specific webhook secret (fallback bypass guard)" do
      # Stored RepositoryLink: "owner/repo" (lowercase).
      # Attacker sends payload with case-mutated repo "Owner/Repo" signed with the fallback ENV secret,
      # hoping exact-case lookup misses → fallback secret is selected → signature passes →
      # case-insensitive dispatch still finds the channel.
      # With case-insensitive find_repository_link, the repo-specific secret is always selected,
      # so a fallback-signed request must be rejected.
      ENV["GITHUB_WEBHOOK_SECRET"] = "attacker-known-fallback"

      payload = {
        action: "created",
        comment: {
          id: 999,
          body: "injected via fallback",
          user: { login: "mallory", type: "User", id: 9 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: "Owner/Repo" }
      }.to_json

      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", ENV["GITHUB_WEBHOOK_SECRET"], payload)

      assert_no_difference -> { Collavre::Comment.where(topic_id: @topic.id).count } do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "issue_comment",
            "X-Hub-Signature-256" => sig
          }
      end
      assert_response :unauthorized
    ensure
      ENV.delete("GITHUB_WEBHOOK_SECRET")
    end

    test "channel-only events (issue_comment) do NOT create creative-level feed comments" do
      # Regression: WebhookProvisioner started auto-subscribing every repo
      # webhook to issue_comment / pull_request_review / pull_request_review_comment
      # so PR channels actually receive deliveries. Those events must only feed
      # attached PR channels — they must NOT spam every linked creative with a
      # system comment for unrelated issues/PRs. `push` and `pull_request`
      # still flow into the feed as before. The feed comment lands on the
      # creative's main_topic (assigned by Comment#assign_main_topic), so we
      # count comments on that topic — must not increment.
      main_topic = @creative.main_topic(fallback_user: @user)
      assert_not_equal @topic.id, main_topic.id, "test depends on @topic != main_topic"

      payload = {
        action: "created",
        comment: {
          id: 501,
          body: "no feed entry please",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      before_main = Collavre::Comment.where(topic_id: main_topic.id).count

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
      assert_equal before_main, Collavre::Comment.where(topic_id: main_topic.id).count,
        "issue_comment must not create a creative-level (main_topic) feed comment"
    end

    test "channel-only event on UNmonitored PR creates neither feed nor topic comment" do
      # Detach the only channel so the PR is unmonitored, then send issue_comment.
      # Nothing should be written anywhere — the event should be dropped entirely.
      @channel.detach!

      payload = {
        action: "created",
        comment: {
          id: 502,
          body: "unmonitored",
          user: { login: "bob", type: "User", id: 2 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      before_any = Collavre::Comment.where(creative_id: @creative.id).count

      post "/github/webhook",
        params: payload,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "issue_comment",
          "X-Hub-Signature-256" => sig
        }

      assert_response :ok
      assert_equal before_any, Collavre::Comment.where(creative_id: @creative.id).count,
        "unmonitored channel-only event must not produce any comment"
    end

    test "pull_request event still creates a creative-level feed comment" do
      # Opposite-direction guard: pull_request is NOT a channel-only event,
      # so it should keep flowing into the creative feed. Use action=opened
      # WITHOUT a topic-link body so auto-attach is a no-op and we only
      # observe the feed write. The feed comment is routed to main_topic.
      main_topic = @creative.main_topic(fallback_user: @user)

      payload = {
        action: "opened",
        pull_request: {
          number: 1234,
          title: "feat: x",
          html_url: "https://github.com/#{@link.repository_full_name}/pull/1234",
          user: { login: "alice" },
          body: ""
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { Collavre::Comment.where(topic_id: main_topic.id).count }, 1 do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request",
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
