# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class WebhooksControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = Collavre.user_class.create!(
        email: "linear-webhook-#{SecureRandom.hex(4)}@example.com",
        name: "Linear Webhook",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      @creative = Collavre::Creative.create!(
        description: "Linear webhook test creative",
        progress: 0.0,
        user: @user
      )
      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-webhook-#{SecureRandom.hex(4)}",
        access_token: "tok-webhook",
        app_actor_id: "app-actor-webhook"
      )
      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  @account,
        linear_project_id: "proj-webhook",
        team_id:           "team-webhook"
      )
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def build_payload(overrides = {})
      {
        action: "update",
        type: "Issue",
        actor: { id: "human-1" },
        webhookTimestamp: (Time.now.to_f * 1000).to_i,
        organizationId: nil,
        data: { id: "iss-1", teamId: "team-webhook" },
        updatedFrom: { title: "old" }
      }.merge(overrides).to_json
    end

    def sign(payload, secret = @project_link.webhook_secret)
      OpenSSL::HMAC.hexdigest("SHA256", secret, payload)
    end

    def post_webhook(payload, signature)
      post "/linear/webhook",
           params: payload,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "Linear-Signature" => signature
           }
    end

    # -------------------------------------------------------------------------
    # Valid signature
    # -------------------------------------------------------------------------

    test "valid signature and fresh timestamp enqueues InboundApplyJob and returns 200" do
      payload = build_payload
      sig = sign(payload)

      assert_enqueued_with(job: CollavreLinear::InboundApplyJob) do
        post_webhook(payload, sig)
      end

      assert_response :ok
    end

    # -------------------------------------------------------------------------
    # Bad signature
    # -------------------------------------------------------------------------

    test "wrong signature returns 401 and does not enqueue" do
      payload = build_payload

      assert_no_enqueued_jobs do
        post_webhook(payload, "deadbeef")
      end

      assert_response :unauthorized
    end

    # -------------------------------------------------------------------------
    # Replay / stale timestamp
    # -------------------------------------------------------------------------

    test "stale timestamp (5 min old) returns 401 and does not enqueue" do
      stale = ((Time.now.to_f * 1000).to_i - 5 * 60 * 1000)
      payload = build_payload(webhookTimestamp: stale)
      sig = sign(payload)

      assert_no_enqueued_jobs do
        post_webhook(payload, sig)
      end

      assert_response :unauthorized
    end

    # -------------------------------------------------------------------------
    # Echo suppression
    # -------------------------------------------------------------------------

    test "our own actor is acked (200) but not enqueued" do
      payload = build_payload(actor: { id: @account.app_actor_id })
      sig = sign(payload)

      assert_no_enqueued_jobs do
        post_webhook(payload, sig)
      end

      assert_response :ok
    end

    # -------------------------------------------------------------------------
    # Bad JSON
    # -------------------------------------------------------------------------

    test "malformed JSON returns 400" do
      raw = "{not-json"
      sig = sign(raw)

      assert_no_enqueued_jobs do
        post_webhook(raw, sig)
      end

      assert_response :bad_request
    end

    # -------------------------------------------------------------------------
    # No fallback secret: unmatched deliveries are rejected, never verified
    # against ENV / admin settings (the secret lives only on the ProjectLink).
    # -------------------------------------------------------------------------

    test "rejects (401) when no ProjectLink matches, even if a would-be ENV secret is set" do
      ENV["LINEAR_WEBHOOK_SECRET"] = "env-fallback-secret"
      # A payload whose team matches no ProjectLink. With the fallback removed,
      # there is no secret to verify against → 401, regardless of ENV.
      payload = build_payload(data: { id: "iss-x", teamId: "unmatched-team" })
      sig = sign(payload, "env-fallback-secret")

      assert_no_enqueued_jobs do
        post_webhook(payload, sig)
      end

      assert_response :unauthorized
    ensure
      ENV.delete("LINEAR_WEBHOOK_SECRET")
    end

    # -------------------------------------------------------------------------
    # Comment deliveries carry no team/project — resolve secret via linked issue
    # -------------------------------------------------------------------------

    test "comment webhook resolves the per-link secret via the linked issue (not ENV)" do
      # ENV secret is deliberately WRONG: if the resolver fell back to it, the
      # signature (made with the project-link secret) would fail → 401.
      ENV["LINEAR_WEBHOOK_SECRET"] = "wrong-env-secret"
      CollavreLinear::IssueLink.create!(
        creative:        @creative,
        project_link:    @project_link,
        linear_issue_id: "iss-cmt-webhook",
        sync_state:      :synced
      )
      # Comment payload has no teamId/projectId — only the parent issue id.
      payload = build_payload(
        type: "Comment",
        data: { id: "cmt-1", issue: { id: "iss-cmt-webhook" } },
        updatedFrom: nil
      )
      sig = sign(payload, @project_link.webhook_secret)

      assert_enqueued_with(job: CollavreLinear::InboundApplyJob) do
        post_webhook(payload, sig)
      end

      assert_response :ok
    ensure
      ENV.delete("LINEAR_WEBHOOK_SECRET")
    end

    # -------------------------------------------------------------------------
    # Cross-link identifier mismatch — a valid team-A signature must not
    # authenticate a write whose other identifiers belong to team B.
    # -------------------------------------------------------------------------

    test "rejects (401) when the signing team's secret validates but projectId belongs to another team" do
      # Team B: a separate account/team → its own (different) webhook secret.
      other_user = Collavre.user_class.create!(
        email: "linear-webhook-b-#{SecureRandom.hex(4)}@example.com",
        name: "Webhook B", password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD, timezone: "UTC"
      )
      other_account = CollavreLinear::Account.create!(
        user: other_user, linear_uid: "uid-webhook-b-#{SecureRandom.hex(4)}",
        access_token: "tok-webhook-b"
      )
      other_root = Collavre::Creative.create!(description: "Root B", user: other_user)
      CollavreLinear::ProjectLink.create!(
        creative: other_root, account: other_account,
        linear_project_id: "proj-B", team_id: "team-B"
      )

      # Signed with team A's secret (find_project_link resolves A via teamId),
      # but projectId points at team B. InboundApplier would apply to B by
      # projectId, so A's secret must NOT authenticate this.
      payload = build_payload(data: { id: "iss-1", teamId: "team-webhook", projectId: "proj-B" })
      sig = sign(payload, @project_link.webhook_secret)

      assert_no_enqueued_jobs do
        post_webhook(payload, sig)
      end
      assert_response :unauthorized
    end

    test "accepts a same-team delivery for a DIFFERENT project (team-shared secret)" do
      # A second project link in the SAME team shares team A's secret, so a
      # delivery naming that project must still be accepted (no over-rejection).
      second_root = Collavre::Creative.create!(description: "Root A2", user: @user)
      CollavreLinear::ProjectLink.create!(
        creative: second_root, account: @account,
        linear_project_id: "proj-webhook-2", team_id: "team-webhook"
      )

      payload = build_payload(data: { id: "iss-2", teamId: "team-webhook", projectId: "proj-webhook-2" })
      sig = sign(payload, @project_link.webhook_secret)

      assert_enqueued_with(job: CollavreLinear::InboundApplyJob) do
        post_webhook(payload, sig)
      end
      assert_response :ok
    end

    # Issue events are routed by data["id"] (the issue itself), and create/
    # reparent by data["parentId"] — neither is the comment-shaped issue id, so
    # both must be checked for cross-team forgery too.

    test "rejects (401) when the Issue event data.id resolves to another team's issue" do
      other_link = build_other_team_project_link
      other_issue = Collavre::Creative.create!(
        description: "Issue B", user: other_link.account.user, parent: other_link.creative
      )
      CollavreLinear::IssueLink.create!(
        creative: other_issue, project_link: other_link, linear_issue_id: "iss-teamB"
      )

      # Signed with team A's secret (teamId=A, no projectId), but data.id names
      # team B's issue — update_issue!/remove_issue! route by data["id"], so A's
      # secret must NOT authenticate a write into B.
      payload = build_payload(data: { id: "iss-teamB", teamId: "team-webhook" })
      sig = sign(payload, @project_link.webhook_secret)

      assert_no_enqueued_jobs do
        post_webhook(payload, sig)
      end
      assert_response :unauthorized
    end

    test "rejects (401) when the Issue event parentId resolves to another team's issue" do
      other_link = build_other_team_project_link
      other_issue = Collavre::Creative.create!(
        description: "Parent B", user: other_link.account.user, parent: other_link.creative
      )
      CollavreLinear::IssueLink.create!(
        creative: other_issue, project_link: other_link, linear_issue_id: "iss-parentB"
      )

      # A create/reparent that resolves its parent to team B's issue would attach
      # a child under B's tree; signed with A's secret this must be rejected.
      payload = build_payload(
        action: "create",
        data: { id: "iss-new", teamId: "team-webhook", parentId: "iss-parentB" }
      )
      sig = sign(payload, @project_link.webhook_secret)

      assert_no_enqueued_jobs do
        post_webhook(payload, sig)
      end
      assert_response :unauthorized
    end

    def build_other_team_project_link
      other_user = Collavre.user_class.create!(
        email: "linear-webhook-b-#{SecureRandom.hex(4)}@example.com",
        name: "Webhook B", password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD, timezone: "UTC"
      )
      other_account = CollavreLinear::Account.create!(
        user: other_user, linear_uid: "uid-webhook-b-#{SecureRandom.hex(4)}",
        access_token: "tok-webhook-b"
      )
      other_root = Collavre::Creative.create!(description: "Root B", user: other_user)
      CollavreLinear::ProjectLink.create!(
        creative: other_root, account: other_account,
        linear_project_id: "proj-B-#{SecureRandom.hex(4)}", team_id: "team-B"
      )
    end
  end
end
