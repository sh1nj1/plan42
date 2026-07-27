require_relative "../../test_helper"

module CollavreGithub
  # The duplicate-comment bug: a repo carried more than one webhook (one per
  # deployed instance sharing this database, plus a legacy singular-path hook),
  # and GitHub fanned each delivery out to all of them with the SAME
  # X-GitHub-Delivery GUID. Every hit was processed independently, so one PR
  # comment produced N topic messages.
  class WebhooksControllerDedupTest < ActionDispatch::IntegrationTest
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

    test "same delivery GUID fanned out to two hooks injects exactly one comment" do
      guid = "5312fd60-8992-11f1-873d-b123fbde0bfb"

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        2.times { post_comment_event(guid: guid, comment_id: 1) }
      end
      assert_response :ok
    end

    test "duplicate delivery answers 200 so GitHub does not retry it" do
      guid = "dup-guid-200"
      post_comment_event(guid: guid, comment_id: 2)
      assert_response :ok

      post_comment_event(guid: guid, comment_id: 2)
      assert_response :ok
    end

    test "distinct delivery GUIDs are both processed" do
      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 2 do
        post_comment_event(guid: "guid-a", comment_id: 3)
        post_comment_event(guid: "guid-b", comment_id: 4)
      end
    end

    test "a claimed GUID is recorded with its event name" do
      post_comment_event(guid: "guid-recorded", comment_id: 5)

      delivery = CollavreGithub::WebhookDelivery.find_by(delivery_guid: "guid-recorded")
      assert delivery, "delivery should be claimed"
      assert_equal "issue_comment", delivery.event
    end

    test "requests without a delivery GUID are still processed" do
      # Nothing to deduplicate on. Dropping these would silently no-op every
      # delivery that arrives without GitHub's header.
      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post_comment_event(guid: nil, comment_id: 6)
      end
      assert_response :ok
    end

    test "an invalid signature does not claim the GUID" do
      # The claim writes a row keyed by an attacker-supplied header. If it ran
      # before signature verification, anyone could pre-claim a GUID and have
      # GitHub's real delivery discarded as a duplicate.
      guid = "poisoned-guid"
      payload = comment_payload(7)
      post "/github/webhooks",
        params: payload,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "issue_comment",
          "X-GitHub-Delivery" => guid,
          "X-Hub-Signature-256" => "sha256=" + ("0" * 64)
        }
      assert_response :unauthorized
      assert_nil CollavreGithub::WebhookDelivery.find_by(delivery_guid: guid)

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post_comment_event(guid: guid, comment_id: 7)
      end
    end

    # A claim that outlives a failed run is worse than the duplicate it
    # prevents: the redelivery — GitHub's, or an operator pressing Redeliver —
    # reuses the GUID, so it would take the duplicate branch, answer 200, and
    # drop the event permanently.
    test "a run that raises releases its claim" do
      guid = "failing-guid"
      @link.update!(markdown_sync_enabled: true)

      assert_raises(RuntimeError) do
        CollavreGithub::MarkdownSyncJob.stub(:perform_later, ->(*) { raise "boom" }) do
          post_push_event(guid: guid)
        end
      end

      assert_nil CollavreGithub::WebhookDelivery.find_by(delivery_guid: guid),
        "a failed run must not leave the GUID claimed"
    end

    test "a redelivery after a failed run is processed instead of dismissed" do
      guid = "retry-after-failure"
      @link.update!(markdown_sync_enabled: true)

      assert_raises(RuntimeError) do
        CollavreGithub::MarkdownSyncJob.stub(:perform_later, ->(*) { raise "boom" }) do
          post_push_event(guid: guid)
        end
      end

      assert_difference -> { @creative.comments.count }, 1 do
        post_push_event(guid: guid)
      end
      assert_response :ok
    end

    test "a successful run marks the delivery processed" do
      post_comment_event(guid: "processed-guid", comment_id: 8)

      delivery = CollavreGithub::WebhookDelivery.find_by(delivery_guid: "processed-guid")
      assert_not_nil delivery.processed_at
    end

    test "an abandoned claim is taken over once it goes stale" do
      # Covers the process that died without running its rescue — SIGKILL, OOM,
      # worker timeout. Without takeover the GUID answers 200 forever and the
      # Redeliver button silently does nothing.
      guid = "abandoned-guid"
      CollavreGithub::WebhookDelivery.create!(
        delivery_guid: guid,
        event: "issue_comment",
        created_at: (CollavreGithub::WebhookDelivery::STALE_CLAIM_AFTER + 1.minute).ago
      )

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post_comment_event(guid: guid, comment_id: 9)
      end

      # Asserted directly, not just via the comment: `dispatch_to_channels`
      # swallows per-channel failures, so a comment count that did not move
      # says nothing about whether the takeover happened. `processed_at` is
      # set only on the path that claimed the delivery.
      assert_not_nil CollavreGithub::WebhookDelivery.find_by(delivery_guid: guid).processed_at,
        "the stale claim should have been taken over and run to completion"
    end

    test "a delivery released mid-race is processed rather than dropped" do
      # The request holding the claim failed and released it in the window
      # between this request's INSERT and its takeover check. Reporting a
      # duplicate here would lose the event for good: the other request has
      # already given up, so nobody would process it.
      #
      # The race is injected rather than sampled — driving two real requests
      # into this window is timing-dependent and would flake.
      guid = "released-mid-race"
      CollavreGithub::WebhookDelivery.create!(
        delivery_guid: guid, event: "issue_comment", created_at: Time.current
      )

      raced = false
      releasing_reclaim = lambda do |claimed_guid, **|
        raced = true
        CollavreGithub::WebhookDelivery.where(delivery_guid: claimed_guid).delete_all
        false
      end

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        CollavreGithub::WebhookDelivery.stub(:reclaim_stale, releasing_reclaim) do
          post_comment_event(guid: guid, comment_id: 11)
        end
      end
      assert raced, "the injected release must actually have been exercised"
      assert_response :ok
    end

    test "a fresh claim still in flight is not taken over" do
      guid = "in-flight-guid"
      CollavreGithub::WebhookDelivery.create!(
        delivery_guid: guid, event: "issue_comment", created_at: Time.current
      )

      assert_no_difference -> { Collavre::Comment.where(topic_id: @topic.id).count } do
        post_comment_event(guid: guid, comment_id: 10)
      end
      assert_response :ok
    end

    test "a processed delivery is never taken over however old it is" do
      guid = "long-done-guid"
      CollavreGithub::WebhookDelivery.create!(
        delivery_guid: guid,
        event: "issue_comment",
        created_at: 30.days.ago,
        processed_at: 30.days.ago
      )

      assert_no_difference -> { Collavre::Comment.where(topic_id: @topic.id).count } do
        post_comment_event(guid: guid, comment_id: 11)
      end
    end

    private

    def push_payload
      {
        ref: "refs/heads/main",
        pusher: { name: "alice" },
        commits: [ { id: "abc1234def", message: "work" } ],
        repository: { full_name: @link.repository_full_name }
      }.to_json
    end

    def post_push_event(guid:)
      payload = push_payload
      post "/github/webhooks",
        params: payload,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "push",
          "X-GitHub-Delivery" => guid,
          "X-Hub-Signature-256" => "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)
        }
    end

    def comment_payload(comment_id)
      {
        action: "created",
        comment: {
          id: comment_id,
          body: "dedup check #{comment_id}",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json
    end

    def post_comment_event(guid:, comment_id:)
      payload = comment_payload(comment_id)
      headers = {
        "Content-Type" => "application/json",
        "X-GitHub-Event" => "issue_comment",
        "X-Hub-Signature-256" => "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)
      }
      headers["X-GitHub-Delivery"] = guid if guid

      post "/github/webhooks", params: payload, headers: headers
    end
  end
end
