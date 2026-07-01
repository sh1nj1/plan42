# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

WebMock.disable_net_connect!

module CollavreLinear
  module Creatives
    class IntegrationsControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      WEBHOOK_RETURN = { id: "wh-ctrl-test-001" }.freeze

      def setup
        @original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        WebMock.reset!

        @user = Collavre.user_class.create!(
          email: "linear-integ-ctrl-#{SecureRandom.hex(4)}@example.com",
          name: "Linear Integration Ctrl",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD,
          timezone: "UTC"
        )
        @creative = Collavre::Creative.create!(
          description: "<p>Integration ctrl creative</p>",
          user: @user
        )
        @account = CollavreLinear::Account.create!(
          user: @user,
          linear_uid: "uid-integ-ctrl-#{SecureRandom.hex(4)}",
          access_token: "tok-integ-ctrl"
        )
      end

      def teardown
        ActiveJob::Base.queue_adapter = @original_adapter
      end

      # -------------------------------------------------------------------------
      # POST /linear/creatives/:creative_id/integration
      # -------------------------------------------------------------------------

      test "create links creative, provisions exactly one webhook, enqueues OutboundSyncJob" do
        sign_in_as(@user)

        stub_provisioner_returning("wh-ctrl-test-001")

        assert_enqueued_with(job: CollavreLinear::OutboundSyncJob) do
          post "/linear/creatives/#{@creative.id}/integration",
               params: { team_id: "team-ctrl-1", linear_project_id: "proj-ctrl-1" },
               as: :json
        end

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_equal "team-ctrl-1", body["project_link"]["team_id"]
        assert_equal "proj-ctrl-1", body["project_link"]["linear_project_id"]
        assert_equal "wh-ctrl-test-001", body["project_link"]["webhook_id"]

        assert_equal 1, CollavreLinear::ProjectLink.where(account: @account).count
        assert_requested_webhook_registration(times: 1)
      end

      test "create is idempotent — second call does not provision a new webhook" do
        sign_in_as(@user)

        # First link + provision
        stub_provisioner_returning("wh-ctrl-test-001")
        post "/linear/creatives/#{@creative.id}/integration",
             params: { team_id: "team-ctrl-2", linear_project_id: "proj-ctrl-2" },
             as: :json
        assert_response :success

        # Second call: same team/project — webhook already exists, WebhookProvisioner skips
        # the API call. Assert that webhookCreate is NOT requested a second time.
        WebMock.reset!
        post "/linear/creatives/#{@creative.id}/integration",
             params: { team_id: "team-ctrl-2", linear_project_id: "proj-ctrl-2" },
             as: :json
        assert_response :success
        assert_not_requested :post, LINEAR_GRAPHQL_ENDPOINT, body: /webhookCreate/

        # There should still be exactly one ProjectLink
        assert_equal 1, CollavreLinear::ProjectLink.where(account: @account).count
      end

      test "create returns forbidden for non-admin user" do
        other = Collavre.user_class.create!(
          email: "linear-nonadmin-#{SecureRandom.hex(4)}@example.com",
          name: "Non Admin",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD,
          timezone: "UTC"
        )
        # Give other user read but not admin permission
        @creative.creative_shares.create!(
          user: other,
          permission: :read
        )
        CollavreLinear::Account.create!(
          user: other,
          linear_uid: "uid-nonadmin-#{SecureRandom.hex(4)}",
          access_token: "tok-nonadmin"
        )

        sign_in_as(other)

        post "/linear/creatives/#{@creative.id}/integration",
             params: { team_id: "team-x", linear_project_id: "proj-x" },
             as: :json

        assert_response :forbidden
      end

      test "create returns unprocessable_entity when user has no Linear account" do
        sign_in_as(@user)
        @account.destroy!

        post "/linear/creatives/#{@creative.id}/integration",
             params: { team_id: "team-y", linear_project_id: "proj-y" },
             as: :json

        assert_response :unprocessable_entity
      end

      test "create returns unprocessable_entity when params are missing" do
        sign_in_as(@user)

        post "/linear/creatives/#{@creative.id}/integration",
             params: { team_id: "team-z" },
             as: :json

        assert_response :unprocessable_entity
      end

      # -------------------------------------------------------------------------
      # DELETE /linear/creatives/:creative_id/integration
      # -------------------------------------------------------------------------

      test "destroy unlinks the creative's project link and calls webhookDelete" do
        sign_in_as(@user)

        link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-destroy-1",
          team_id: "team-destroy-1",
          webhook_id: "wh-destroy-001"
        )

        stub_webhook_delete_returning(true)

        delete "/linear/creatives/#{@creative.id}/integration", as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_not CollavreLinear::ProjectLink.exists?(link.id)
        assert_requested_webhook_delete(webhook_id: "wh-destroy-001", times: 1)
      end

      test "destroy still unlinks even when webhookDelete raises Client::Error" do
        sign_in_as(@user)

        link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-destroy-2",
          team_id: "team-destroy-2",
          webhook_id: "wh-destroy-002"
        )

        stub_request(:post, LINEAR_GRAPHQL_ENDPOINT)
          .with(body: /webhookDelete/)
          .to_return(
            status: 200,
            body: { errors: [{ message: "Webhook not found" }] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        delete "/linear/creatives/#{@creative.id}/integration", as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_not CollavreLinear::ProjectLink.exists?(link.id)
      end

      test "destroy returns not_found when no link exists" do
        sign_in_as(@user)

        delete "/linear/creatives/#{@creative.id}/integration", as: :json

        assert_response :not_found
      end

      test "destroy returns forbidden for non-admin user" do
        other = Collavre.user_class.create!(
          email: "linear-nonadmin-destroy-#{SecureRandom.hex(4)}@example.com",
          name: "Non Admin Destroy",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD,
          timezone: "UTC"
        )
        @creative.creative_shares.create!(
          user: other,
          permission: :read
        )
        CollavreLinear::Account.create!(
          user: other,
          linear_uid: "uid-nonadmin-destroy-#{SecureRandom.hex(4)}",
          access_token: "tok-nonadmin-destroy"
        )

        sign_in_as(other)

        delete "/linear/creatives/#{@creative.id}/integration", as: :json

        assert_response :forbidden
      end

      # -------------------------------------------------------------------------
      # POST /linear/creatives/:creative_id/integration/resync
      # -------------------------------------------------------------------------

      test "resync enqueues OutboundSyncJob when link exists" do
        sign_in_as(@user)

        CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-resync-1",
          team_id: "team-resync-1",
          webhook_id: "wh-resync-001"
        )

        assert_enqueued_with(job: CollavreLinear::OutboundSyncJob) do
          post "/linear/creatives/#{@creative.id}/integration/resync", as: :json
        end

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
      end

      test "resync returns not_found when no link exists" do
        sign_in_as(@user)

        post "/linear/creatives/#{@creative.id}/integration/resync", as: :json

        assert_response :not_found
      end

      test "resync returns forbidden for non-admin user" do
        other = Collavre.user_class.create!(
          email: "linear-nonadmin-resync-#{SecureRandom.hex(4)}@example.com",
          name: "Non Admin Resync",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD,
          timezone: "UTC"
        )
        @creative.creative_shares.create!(
          user: other,
          permission: :read
        )
        CollavreLinear::Account.create!(
          user: other,
          linear_uid: "uid-nonadmin-resync-#{SecureRandom.hex(4)}",
          access_token: "tok-nonadmin-resync"
        )

        sign_in_as(other)

        post "/linear/creatives/#{@creative.id}/integration/resync", as: :json

        assert_response :forbidden
      end

      private

      LINEAR_GRAPHQL_ENDPOINT = "https://api.linear.app/graphql"

      # Stub the Linear GraphQL endpoint so WebhookProvisioner's register_webhook
      # call succeeds and returns the given webhook id.
      def stub_provisioner_returning(webhook_id)
        stub_request(:post, LINEAR_GRAPHQL_ENDPOINT)
          .with(body: /webhookCreate/)
          .to_return(
            status: 200,
            body: {
              data: {
                webhookCreate: {
                  success: true,
                  webhook: { id: webhook_id }
                }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      def assert_requested_webhook_registration(times: 1)
        assert_requested :post, LINEAR_GRAPHQL_ENDPOINT,
                         body: /webhookCreate/,
                         times: times
      end

      def stub_webhook_delete_returning(success)
        stub_request(:post, LINEAR_GRAPHQL_ENDPOINT)
          .with(body: /webhookDelete/)
          .to_return(
            status: 200,
            body: {
              data: {
                webhookDelete: { success: success }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      def assert_requested_webhook_delete(webhook_id:, times: 1)
        assert_requested :post, LINEAR_GRAPHQL_ENDPOINT,
                         body: /webhookDelete/,
                         times: times
        assert_requested :post, LINEAR_GRAPHQL_ENDPOINT, times: times do |req|
          body = JSON.parse(req.body)
          body["query"].include?("webhookDelete") && body["variables"]["id"] == webhook_id
        end
      end
    end
  end
end
