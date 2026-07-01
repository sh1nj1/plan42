# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class WebhookProvisionerTest < ActiveSupport::TestCase
    def setup
      @user = Collavre.user_class.create!(
        email: "webhook-prov-test@example.com",
        name: "Webhook Prov Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      @creative = Collavre::Creative.create!(
        description: "<p>Provisioner test creative</p>",
        user: @user
      )
      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-webhook-prov",
        access_token: "tok-webhook-prov"
      )
      @link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account: @account,
        linear_project_id: "proj-wh-1",
        team_id: "team-wh-1"
      )
      @webhook_url = "https://example.com/linear/webhook"
    end

    # ---------------------------------------------------------------------------
    # ensure_for — happy path: provisions exactly one webhook
    # ---------------------------------------------------------------------------
    test "ensure_for calls register_webhook once and stores the returned id" do
      stub_client = Minitest::Mock.new
      stub_client.expect :register_webhook, { id: "wh-new-001" }, [],
                         url: @webhook_url,
                         secret: @link.webhook_secret,
                         team_id: @link.team_id,
                         resource_types: CollavreLinear::WebhookProvisioner::RESOURCE_TYPES

      CollavreLinear::Client.stub :new, stub_client do
        result = CollavreLinear::WebhookProvisioner.ensure_for(
          project_link: @link,
          webhook_url:  @webhook_url
        )
        assert_equal :created, result
      end

      stub_client.verify
      assert_equal "wh-new-001", @link.reload.webhook_id
    end

    # ---------------------------------------------------------------------------
    # ensure_for — idempotent: skip if webhook_id already present on this link
    # ---------------------------------------------------------------------------
    test "ensure_for skips API call when project_link already has a webhook_id" do
      @link.update_column(:webhook_id, "wh-existing-999")

      spy = Minitest::Mock.new
      # register_webhook must NOT be called — we assert via spy.verify (no expectations set)
      CollavreLinear::Client.stub :new, spy do
        result = CollavreLinear::WebhookProvisioner.ensure_for(
          project_link: @link,
          webhook_url:  @webhook_url
        )
        assert_equal :skipped, result
      end

      spy.verify
      # webhook_id unchanged
      assert_equal "wh-existing-999", @link.reload.webhook_id
    end

    # ---------------------------------------------------------------------------
    # ensure_for — idempotent: skip when another link for the same team has webhook_id
    # ---------------------------------------------------------------------------
    test "ensure_for skips when another ProjectLink for the same team already has a webhook_id" do
      # Create a second creative + link for the same team, already provisioned
      other_creative = Collavre::Creative.create!(
        description: "<p>Other creative</p>",
        user: @user
      )
      other_link = CollavreLinear::ProjectLink.create!(
        creative: other_creative,
        account: @account,
        linear_project_id: "proj-wh-2",
        team_id: "team-wh-1",  # same team
        webhook_id: "wh-shared-777"
      )

      spy = Minitest::Mock.new
      CollavreLinear::Client.stub :new, spy do
        result = CollavreLinear::WebhookProvisioner.ensure_for(
          project_link: @link,
          webhook_url:  @webhook_url
        )
        assert_equal :skipped, result
      end

      spy.verify
      # The shared webhook_id should be copied to this link
      assert_equal "wh-shared-777", @link.reload.webhook_id
    end

    # ---------------------------------------------------------------------------
    # ensure_for — returns :failed on Client::Error
    # ---------------------------------------------------------------------------
    test "ensure_for returns :failed when register_webhook raises Client::Error" do
      error_client = Object.new
      def error_client.register_webhook(**_kwargs)
        raise CollavreLinear::Client::Error, "network timeout"
      end

      CollavreLinear::Client.stub :new, error_client do
        result = CollavreLinear::WebhookProvisioner.ensure_for(
          project_link: @link,
          webhook_url:  @webhook_url
        )
        assert_equal :failed, result
      end

      assert_nil @link.reload.webhook_id
    end

    # ---------------------------------------------------------------------------
    # deregister — calls delete_webhook when webhook_id is present
    # ---------------------------------------------------------------------------
    test "deregister calls delete_webhook with the stored webhook_id" do
      @link.update_column(:webhook_id, "wh-to-remove-001")

      deleted_ids = []
      stub_client = Object.new
      stub_client.define_singleton_method(:delete_webhook) { |id| deleted_ids << id; true }

      CollavreLinear::Client.stub :new, stub_client do
        CollavreLinear::WebhookProvisioner.deregister(project_link: @link)
      end

      assert_equal [ "wh-to-remove-001" ], deleted_ids
    end

    test "deregister is a no-op when webhook_id is blank" do
      assert_nil @link.webhook_id

      spy = Minitest::Mock.new
      # delete_webhook must NOT be called — no expectations set, verify will catch any calls
      CollavreLinear::Client.stub :new, spy do
        CollavreLinear::WebhookProvisioner.deregister(project_link: @link)
      end

      spy.verify
    end

    test "deregister swallows Client::Error so callers can proceed" do
      @link.update_column(:webhook_id, "wh-failing-001")

      error_client = Object.new
      def error_client.delete_webhook(_id)
        raise CollavreLinear::Client::Error, "not found"
      end

      CollavreLinear::Client.stub :new, error_client do
        assert_nothing_raised do
          CollavreLinear::WebhookProvisioner.deregister(project_link: @link)
        end
      end
    end
  end
end
