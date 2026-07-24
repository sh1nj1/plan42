# frozen_string_literal: true

# Load the engine's test_helper (not the app's) so WebMock + GitHub stubs are
# available for the webhook-provisioning test below.
require_relative "../../../test_helper"

module CollavreGithub
  module Tools
    class PrMonitorServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @topic = Collavre::Topic.create!(name: "T", creative: @creative, user: @user)
        Collavre::Current.user = @user
      end

      teardown do
        Collavre::Current.user = nil
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

      test "first attach seeds chip label and link so the chip is clickable before any webhook fires" do
        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )
        channel = GithubPrChannel.find(result[:channel_id])
        assert_equal "PR #77", channel.latest_label
        assert_equal "https://github.com/owner/repo/pull/77", channel.latest_link
      end

      test "first attach injects an announcement comment into the topic creative" do
        assert_difference -> { @creative.comments.count }, 1 do
          PrMonitorService.new.call(
            topic_id: @topic.id,
            pr_url: "https://github.com/owner/repo/pull/77"
          )
        end
        comment = @creative.comments.order(:created_at).last
        assert_equal @topic.id, comment.topic_id
        assert_includes comment.content, "PR #77"
        assert_includes comment.content, "https://github.com/owner/repo/pull/77"
      end

      test "idempotent re-attach does not inject a duplicate announcement" do
        PrMonitorService.new.call(topic_id: @topic.id, pr_url: "https://github.com/owner/repo/pull/77")
        assert_no_difference -> { @creative.comments.count } do
          PrMonitorService.new.call(topic_id: @topic.id, pr_url: "https://github.com/owner/repo/pull/77")
        end
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

      test "denies attachment when current user lacks write permission on the topic's creative" do
        outsider = users(:two)
        Collavre::Current.user = outsider

        assert_raises(CollavreGithub::Tools::PermissionDeniedError) do
          PrMonitorService.new.call(
            topic_id: @topic.id,
            pr_url: "https://github.com/owner/repo/pull/77"
          )
        end
        assert_equal 0, GithubPrChannel.where(topic_id: @topic.id).count
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

      test "detached->active re-attach re-seeds the chip label/link cache and announces in the topic" do
        # Simulate a previously-attached channel that was auto-detached when
        # the PR closed: latest_label / latest_link were populated at one
        # point but no fresh announcement has run since reactivation.
        channel = GithubPrChannel.create!(
          topic_id: @topic.id,
          config: { "repo_full_name" => "owner/repo", "pr_number" => 77 },
          state: :detached,
          latest_label: nil,
          latest_link: nil
        )

        assert_difference -> { @creative.comments.count }, 1 do
          PrMonitorService.new.call(
            topic_id: @topic.id,
            pr_url: "https://github.com/owner/repo/pull/77"
          )
        end

        channel.reload
        assert channel.active?
        assert_equal "PR #77", channel.latest_label
        assert_equal "https://github.com/owner/repo/pull/77", channel.latest_link
      end

      test "reactivation clears dismissed_at and resets pr_state so the chip resurfaces under not_dismissed" do
        # Scenario: user dismissed the post-close chip (X button), which set
        # state=:detached AND dismissed_at to keep the chip hidden under the
        # new not_dismissed render scope. Calling pr_monitor again must clear
        # dismissed_at + reset pr_state to "open", or the tool returns success
        # while the chip stays invisible.
        channel = GithubPrChannel.create!(
          topic_id: @topic.id,
          config: { "repo_full_name" => "owner/repo", "pr_number" => 77, "pr_state" => "merged" },
          state: :detached,
          dismissed_at: 1.hour.ago
        )

        PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )

        channel.reload
        assert channel.active?
        assert_nil channel.dismissed_at
        assert_equal "open", channel.pr_state
      end

      test "active->active idempotent re-attach does not re-announce" do
        PrMonitorService.new.call(topic_id: @topic.id, pr_url: "https://github.com/owner/repo/pull/77")
        assert_no_difference -> { @creative.comments.count } do
          PrMonitorService.new.call(topic_id: @topic.id, pr_url: "https://github.com/owner/repo/pull/77")
        end
      end

      test "returns webhook_warning when no RepositoryLink covers the topic creative scope" do
        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )
        # No CollavreGithub::RepositoryLink exists for owner/repo in @creative's
        # subtree, so pr_monitor cannot provision webhook events. It should
        # surface this in the response rather than silently succeeding.
        assert_includes result[:webhook_warning].to_s, "no RepositoryLink found"
      end

      test "auto-provisions PR-channel webhook events when a RepositoryLink exists" do
        account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "pr-monitor-prov-1",
          login: "owner",
          name: @user.name,
          token: "ghp-test-token-prov"
        )
        link = CollavreGithub::RepositoryLink.create!(
          creative: @creative,
          github_account: account,
          repository_full_name: "owner/repo",
          webhook_secret: "secret-1234567890"
        )

        # Existing hook on the repo is subscribed only to `pull_request` —
        # exactly the production bug. WebhookProvisioner must PATCH it to add
        # the PR-channel events.
        webhook_url = CollavreGithub::Engine.routes.url_helpers.webhooks_url(
          Rails.application.config.action_mailer.default_url_options
        )
        existing_hook_id = 42424242
        # Use regex so Octokit's `?per_page=100` query suffix still matches.
        stub_request(:get, %r{https://api\.github\.com/repos/owner/repo/hooks})
          .to_return(
            status: 200,
            body: [ { id: existing_hook_id, config: { url: webhook_url }, events: [ "pull_request" ] } ].to_json,
            headers: { "Content-Type" => "application/json" }
          )

        patched_events = nil
        edit_stub = stub_request(:patch, "https://api.github.com/repos/owner/repo/hooks/#{existing_hook_id}")
          .with do |req|
            body = JSON.parse(req.body)
            patched_events = body["events"]
            true
          end
          .to_return(
            status: 200,
            body: { id: existing_hook_id, active: true }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )

        assert result[:ok]
        assert_nil result[:webhook_warning]
        assert_requested(edit_stub)
        assert_includes patched_events, "issue_comment"
        assert_includes patched_events, "pull_request_review"
        assert_includes patched_events, "pull_request_review_comment"
        assert_includes patched_events, "pull_request"
      end

      test "surfaces webhook_warning when GitHub rejects the hook PATCH" do
        # CollavreGithub::Client rescues Octokit/Faraday errors silently and
        # returns nil. Without surfacing that result, pr_monitor would report
        # success even though the hook events were never updated. Confirm the
        # warning is included in the MCP response when GitHub returns an error.
        account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "pr-monitor-prov-fail",
          login: "owner",
          name: @user.name,
          token: "ghp-test-token-fail"
        )
        CollavreGithub::RepositoryLink.create!(
          creative: @creative,
          github_account: account,
          repository_full_name: "owner/repo",
          webhook_secret: "secret-fail-1234"
        )

        webhook_url = CollavreGithub::Engine.routes.url_helpers.webhooks_url(
          Rails.application.config.action_mailer.default_url_options
        )
        existing_hook_id = 99999999
        stub_request(:get, %r{https://api\.github\.com/repos/owner/repo/hooks})
          .to_return(
            status: 200,
            body: [ { id: existing_hook_id, config: { url: webhook_url }, events: [ "pull_request" ] } ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
        # GitHub rejects the PATCH (e.g. token lost admin perms). Client
        # rescues + returns nil, so ensure_webhook must surface :failed.
        stub_request(:patch, "https://api.github.com/repos/owner/repo/hooks/#{existing_hook_id}")
          .to_return(status: 403, body: { message: "Resource not accessible" }.to_json,
                     headers: { "Content-Type" => "application/json" })

        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )

        assert result[:ok]
        assert result[:webhook_warning].present?,
          "expected webhook_warning when GitHub rejects PATCH, got: #{result.inspect}"
        assert_includes result[:webhook_warning], "webhook provisioning failed"
      end

      test "provisions through the global primary link when topic's scoped link is non-primary" do
        # When the same repo is linked from multiple creatives,
        # WebhookProvisioner only PATCHes hook events for the lowest-id
        # (primary) link. Non-primary links short-circuit to secret alignment
        # and never call edit_hook. So we must hand the GLOBAL primary to the
        # provisioner, not the topic-scoped link, otherwise the existing hook
        # keeps its old event list.
        sibling_creative = Collavre::Creative.create!(
          description: "Sibling",
          user: @user
        )
        # One account per user (UNIQUE constraint on github_accounts.user_id).
        # Both RepositoryLinks share this account; only their creative scope
        # and webhook_secret differ.
        account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "pr-monitor-prov-shared",
          login: "owner",
          name: @user.name,
          token: "ghp-test-token-primary"
        )
        # Lower id (created first) → becomes the global primary. Lives on a
        # sibling creative outside the topic's subtree.
        CollavreGithub::RepositoryLink.create!(
          creative: sibling_creative,
          github_account: account,
          repository_full_name: "owner/repo",
          webhook_secret: "primary-secret-1234"
        )
        # Higher id, sits in the topic's creative subtree → satisfies the
        # authorization gate but is NOT the global primary.
        CollavreGithub::RepositoryLink.create!(
          creative: @creative,
          github_account: account,
          repository_full_name: "owner/repo",
          webhook_secret: "scoped-secret-5678"
        )

        webhook_url = CollavreGithub::Engine.routes.url_helpers.webhooks_url(
          Rails.application.config.action_mailer.default_url_options
        )
        existing_hook_id = 51515151
        stub_request(:get, %r{https://api\.github\.com/repos/owner/repo/hooks})
          .to_return(
            status: 200,
            body: [ { id: existing_hook_id, config: { url: webhook_url }, events: [ "pull_request" ] } ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
        patched_body = nil
        edit_stub = stub_request(:patch, "https://api.github.com/repos/owner/repo/hooks/#{existing_hook_id}")
          .with do |req|
            patched_body = JSON.parse(req.body)
            true
          end
          .to_return(
            status: 200,
            body: { id: existing_hook_id, active: true }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = PrMonitorService.new.call(
          topic_id: @topic.id,
          pr_url: "https://github.com/owner/repo/pull/77"
        )

        assert result[:ok]
        assert_nil result[:webhook_warning]
        # The PATCH must fire — under the old behavior, pr_monitor handed
        # WebhookProvisioner the scoped (non-primary) link, which would have
        # short-circuited to `align_link_secret` and never called edit_hook.
        assert_requested(edit_stub)
        # And the secret should track the GLOBAL primary's secret, not the
        # scoped link's. (WebhookProvisioner aligns the hook secret to the
        # primary link's webhook_secret.)
        assert_equal "primary-secret-1234", patched_body["config"]["secret"]
      end
    end
  end
end
