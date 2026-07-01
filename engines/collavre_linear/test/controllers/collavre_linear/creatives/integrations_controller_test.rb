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

        assert body["webhook_provisioned"],
          "create must report a successful webhook provisioning outcome"
        assert_nil body["warning"],
          "no warning should surface on a successful provisioning"
      end

      test "create rejects linking a descendant when an ancestor is already linked" do
        sign_in_as(@user)

        # @creative (ancestor) already linked to a project.
        CollavreLinear::ProjectLink.create!(
          creative:          @creative.effective_origin,
          account:           @account,
          linear_project_id: "proj-ancestor",
          team_id:           "team-ov"
        )
        child = Collavre::Creative.create!(
          description: "<p>child</p>", user: @user, parent: @creative
        )

        assert_no_difference -> { CollavreLinear::ProjectLink.count } do
          post "/linear/creatives/#{child.id}/integration",
               params: { team_id: "team-ov", linear_project_id: "proj-descendant" },
               as: :json
        end

        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre_linear.errors.overlapping_link"),
          JSON.parse(response.body)["error"]
      end

      test "create rejects linking a DISJOINT creative to an already-linked Linear project" do
        sign_in_as(@user)

        # A totally separate Collavre root (not an ancestor/descendant of
        # @creative) is already linked to proj-shared. Inbound webhooks resolve
        # the project with an UNSCOPED find_by(linear_project_id:), so a second
        # ProjectLink for the same project would make imports/updates land on
        # whichever row the DB returns while both roots export into it. The one
        # Linear project must map to exactly one Collavre root.
        other_root = Collavre::Creative.create!(
          description: "<p>disjoint other root</p>", user: @user
        )
        CollavreLinear::ProjectLink.create!(
          creative:          other_root.effective_origin,
          account:           @account,
          linear_project_id: "proj-shared",
          team_id:           "team-shared"
        )

        assert_no_difference -> { CollavreLinear::ProjectLink.count } do
          post "/linear/creatives/#{@creative.id}/integration",
               params: { team_id: "team-shared", linear_project_id: "proj-shared" },
               as: :json
        end

        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre_linear.errors.overlapping_link"),
          JSON.parse(response.body)["error"]
      end

      test "create rejects a SECOND link to a DIFFERENT project on the same origin" do
        sign_in_as(@user)

        # @origin already linked to project A. The ancestor/descendant guard
        # excludes @origin itself (to keep same-project re-link idempotent), so
        # this different-project case must be rejected by the origin guard.
        CollavreLinear::ProjectLink.create!(
          creative:          @creative.effective_origin,
          account:           @account,
          linear_project_id: "proj-a",
          team_id:           "team-oc"
        )

        assert_no_difference -> { CollavreLinear::ProjectLink.count } do
          post "/linear/creatives/#{@creative.id}/integration",
               params: { team_id: "team-oc", linear_project_id: "proj-b" },
               as: :json
        end

        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre_linear.errors.overlapping_link"),
          JSON.parse(response.body)["error"]
      end

      test "create rejects a subtree overlap owned by ANOTHER Linear account" do
        sign_in_as(@user)

        # A different admin, with their OWN Linear account, already linked the
        # ancestor. The exporter resolves ProjectLink/IssueLink per creative
        # WITHOUT account scope, so a second account claiming a descendant would
        # hijack the subtree — the overlap guard must span all accounts.
        other_user = Collavre.user_class.create!(
          email: "linear-integ-other-#{SecureRandom.hex(4)}@example.com",
          name: "Other Linear Admin",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD,
          timezone: "UTC"
        )
        other_account = CollavreLinear::Account.create!(
          user: other_user,
          linear_uid: "uid-integ-other-#{SecureRandom.hex(4)}",
          access_token: "tok-integ-other"
        )
        CollavreLinear::ProjectLink.create!(
          creative:          @creative.effective_origin,
          account:           other_account,
          linear_project_id: "proj-other",
          team_id:           "team-other"
        )
        child = Collavre::Creative.create!(
          description: "<p>child</p>", user: @user, parent: @creative
        )

        assert_no_difference -> { CollavreLinear::ProjectLink.count } do
          post "/linear/creatives/#{child.id}/integration",
               params: { team_id: "team-mine", linear_project_id: "proj-mine" },
               as: :json
        end

        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre_linear.errors.overlapping_link"),
          JSON.parse(response.body)["error"]
      end

      test "create registers the webhook URL WITH the /linear mount prefix" do
        sign_in_as(@user)

        captured_url = nil
        provisioner = lambda do |project_link:, webhook_url:|
          captured_url = webhook_url
          :created
        end

        CollavreLinear::WebhookProvisioner.stub(:ensure_for, provisioner) do
          post "/linear/creatives/#{@creative.id}/integration",
               params: { team_id: "team-prefix", linear_project_id: "proj-prefix" },
               as: :json
        end

        assert_response :success
        # A detached engine url_helper omits the mount prefix, registering
        # https://host/webhook — a 404 in production. The real route is
        # /linear/webhook, so the registered URL MUST carry the prefix.
        assert_includes captured_url, "/linear/webhook",
          "webhook URL registered with Linear must include the /linear mount prefix"
      end

      test "create surfaces a warning (but still succeeds) when webhook provisioning fails" do
        sign_in_as(@user)

        CollavreLinear::WebhookProvisioner.stub(:ensure_for, :failed) do
          post "/linear/creatives/#{@creative.id}/integration",
               params: { team_id: "team-fail", linear_project_id: "proj-fail" },
               as: :json
        end

        # The link + outbound sync still work, so the request succeeds.
        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_equal 1, CollavreLinear::ProjectLink.where(account: @account).count

        # But the failed inbound webhook setup must be surfaced, not silent.
        assert_equal false, body["webhook_provisioned"]
        assert_not_nil body["warning"],
          "a failed webhook provisioning must surface a warning to the user"
      end

      test "create enqueues OutboundSyncJob for the whole existing subtree" do
        sign_in_as(@user)

        child1 = Collavre::Creative.create!(
          description: "<p>child 1</p>", user: @user, parent: @creative
        )
        child2 = Collavre::Creative.create!(
          description: "<p>child 2</p>", user: @user, parent: @creative
        )

        stub_provisioner_returning("wh-subtree-001")

        assert_enqueued_jobs 3, only: CollavreLinear::OutboundSyncJob do
          post "/linear/creatives/#{@creative.id}/integration",
               params: { team_id: "team-subtree", linear_project_id: "proj-subtree" },
               as: :json
        end

        assert_response :success
        enqueued_ids = enqueued_jobs
          .select { |j| j[:job] == CollavreLinear::OutboundSyncJob }
          .map { |j| j[:args].first }
        assert_equal [ @creative.id, child1.id, child2.id ].sort, enqueued_ids.sort
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
            body: { errors: [ { message: "Webhook not found" } ] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        delete "/linear/creatives/#{@creative.id}/integration", as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_not CollavreLinear::ProjectLink.exists?(link.id)
      end

      test "destroy cascades to issue links and comment links (no FK 500)" do
        sign_in_as(@user)

        link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-destroy-cascade",
          team_id: "team-destroy-cascade",
          webhook_id: "wh-destroy-cascade"
        )
        child = Collavre::Creative.create!(
          description: "<p>child</p>",
          user: @user,
          parent: @creative
        )
        issue_link = CollavreLinear::IssueLink.create!(
          creative: child,
          project_link: link,
          linear_issue_id: "iss-cascade-1",
          sync_state: :synced
        )
        comment = child.comments.create!(content: "c", user: @user, skip_dispatch: true)
        comment_link = CollavreLinear::CommentLink.create!(
          comment_id: comment.id,
          linear_comment_id: "cmt-cascade-1",
          issue_link: issue_link
        )

        stub_webhook_delete_returning(true)

        delete "/linear/creatives/#{@creative.id}/integration", as: :json

        assert_response :success
        assert_not CollavreLinear::ProjectLink.exists?(link.id)
        assert_not CollavreLinear::IssueLink.exists?(issue_link.id), "IssueLink should cascade-delete"
        assert_not CollavreLinear::CommentLink.exists?(comment_link.id), "CommentLink should cascade-delete"
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

      test "resync enqueues OutboundSyncJob for the whole subtree" do
        sign_in_as(@user)

        child1 = Collavre::Creative.create!(
          description: "<p>resync child 1</p>", user: @user, parent: @creative
        )
        child2 = Collavre::Creative.create!(
          description: "<p>resync child 2</p>", user: @user, parent: @creative
        )

        CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-resync-subtree",
          team_id: "team-resync-subtree",
          webhook_id: "wh-resync-subtree-001"
        )

        assert_enqueued_jobs 3, only: CollavreLinear::OutboundSyncJob do
          post "/linear/creatives/#{@creative.id}/integration/resync", as: :json
        end

        assert_response :success
        enqueued_ids = enqueued_jobs
          .select { |j| j[:job] == CollavreLinear::OutboundSyncJob }
          .map { |j| j[:args].first }
        assert_equal [ @creative.id, child1.id, child2.id ].sort, enqueued_ids.sort
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

      # -------------------------------------------------------------------------
      # POST /linear/creatives/:creative_id/integration/regenerate_secret
      # -------------------------------------------------------------------------

      test "regenerate_secret rolls the project link's webhook signing secret" do
        sign_in_as(@user)

        link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-regen-1",
          team_id: "team-regen-1"
        )
        old_secret = link.webhook_secret

        post "/linear/creatives/#{@creative.id}/integration/regenerate_secret", as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_not_equal old_secret, link.reload.webhook_secret
      end

      test "regenerate_secret returns not_found when no link exists" do
        sign_in_as(@user)

        post "/linear/creatives/#{@creative.id}/integration/regenerate_secret", as: :json

        assert_response :not_found
      end

      test "regenerate_secret returns forbidden for non-admin user" do
        other = Collavre.user_class.create!(
          email: "linear-nonadmin-regen-#{SecureRandom.hex(4)}@example.com",
          name: "Non Admin Regen",
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
          linear_uid: "uid-nonadmin-regen-#{SecureRandom.hex(4)}",
          access_token: "tok-nonadmin-regen"
        )

        sign_in_as(other)

        post "/linear/creatives/#{@creative.id}/integration/regenerate_secret", as: :json

        assert_response :forbidden
      end

      # -------------------------------------------------------------------------
      # GET /linear/creatives/:creative_id/integration/options (link picker)
      # -------------------------------------------------------------------------

      test "options returns teams and projects for the connected account" do
        sign_in_as(@user)

        stub_request(:post, LINEAR_GRAPHQL_ENDPOINT)
          .with(body: /teams/)
          .to_return(
            status: 200,
            body: { data: { teams: { nodes: [ { id: "t1", name: "Eng", key: "ENG" } ] } } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
        stub_request(:post, LINEAR_GRAPHQL_ENDPOINT)
          .with(body: /projects/)
          .to_return(
            status: 200,
            body: { data: { projects: { nodes: [ { id: "p1", name: "Roadmap", teams: { nodes: [ { id: "t1" } ] } } ] } } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        get "/linear/creatives/#{@creative.id}/integration/options", as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "t1", body["teams"].first["id"]
        assert_equal "Roadmap", body["projects"].first["name"]
        assert_equal [ "t1" ], body["projects"].first["team_ids"]
      end

      test "options surfaces a bad_gateway when Linear errors" do
        sign_in_as(@user)

        stub_request(:post, LINEAR_GRAPHQL_ENDPOINT)
          .to_return(
            status: 200,
            body: { errors: [ { message: "Unauthorized" } ] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        get "/linear/creatives/#{@creative.id}/integration/options", as: :json

        assert_response :bad_gateway
        assert_match "Unauthorized", JSON.parse(response.body)["error"]
      end

      test "options returns forbidden for non-admin user" do
        other = Collavre.user_class.create!(
          email: "linear-nonadmin-options-#{SecureRandom.hex(4)}@example.com",
          name: "Non Admin Options",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD,
          timezone: "UTC"
        )
        @creative.creative_shares.create!(user: other, permission: :read)
        CollavreLinear::Account.create!(
          user: other,
          linear_uid: "uid-nonadmin-options-#{SecureRandom.hex(4)}",
          access_token: "tok-nonadmin-options"
        )

        sign_in_as(other)

        get "/linear/creatives/#{@creative.id}/integration/options", as: :json

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
