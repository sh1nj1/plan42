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
    # Fallback secret via ENV when no ProjectLink matches
    # -------------------------------------------------------------------------

    test "falls back to ENV secret when no ProjectLink team matches" do
      ENV["LINEAR_WEBHOOK_SECRET"] = "env-fallback-secret"
      # A payload whose team does not match any ProjectLink; must verify against ENV.
      payload = build_payload(data: { id: "iss-x", teamId: "unmatched-team" })
      sig = sign(payload, "env-fallback-secret")

      assert_enqueued_with(job: CollavreLinear::InboundApplyJob) do
        post_webhook(payload, sig)
      end

      assert_response :ok
    ensure
      ENV.delete("LINEAR_WEBHOOK_SECRET")
    end
  end
end
