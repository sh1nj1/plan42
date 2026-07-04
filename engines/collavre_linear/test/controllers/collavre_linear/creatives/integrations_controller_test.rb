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

      test "create links creative and enqueues OutboundSyncJob (no auto-provisioning)" do
        sign_in_as(@user)

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

        assert_equal 1, CollavreLinear::ProjectLink.where(account: @account).count
        # The webhook is set up by hand (no admin scope), so linking makes NO
        # Linear API call to register one.
        assert_not_requested :post, LINEAR_GRAPHQL_ENDPOINT, body: /webhookCreate/
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

      test "create enqueues OutboundSyncJob for the whole existing subtree" do
        sign_in_as(@user)

        child1 = Collavre::Creative.create!(
          description: "<p>child 1</p>", user: @user, parent: @creative
        )
        child2 = Collavre::Creative.create!(
          description: "<p>child 2</p>", user: @user, parent: @creative
        )

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

      test "create is idempotent — re-linking the same origin/project keeps one link" do
        sign_in_as(@user)

        post "/linear/creatives/#{@creative.id}/integration",
             params: { team_id: "team-ctrl-2", linear_project_id: "proj-ctrl-2" },
             as: :json
        assert_response :success

        # Re-linking the same origin to the same project is a no-op upsert.
        post "/linear/creatives/#{@creative.id}/integration",
             params: { team_id: "team-ctrl-2", linear_project_id: "proj-ctrl-2" },
             as: :json
        assert_response :success

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

      test "destroy unlinks the creative's project link (no remote webhook call)" do
        sign_in_as(@user)

        link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-destroy-1",
          team_id: "team-destroy-1"
        )

        delete "/linear/creatives/#{@creative.id}/integration", as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_not CollavreLinear::ProjectLink.exists?(link.id)
        # The webhook is managed by hand in Linear (we hold no id for it), so
        # unlink must NOT attempt a remote deregistration.
        assert_not_requested :post, LINEAR_GRAPHQL_ENDPOINT, body: /webhookDelete/
      end

      test "destroy cascades to issue links and comment links (no FK 500)" do
        sign_in_as(@user)

        link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-destroy-cascade",
          team_id: "team-destroy-cascade"
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

      test "resync reopens conflicted issue links so the export can push" do
        sign_in_as(@user)

        project_link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-resync-conflict",
          team_id: "team-resync-conflict",
          webhook_id: "wh-resync-conflict-001"
        )
        # A link frozen at :conflict by an inbound race. Without reopening it, the
        # exporter's `return if conflict?` makes the resync a silent no-op.
        conflicted = CollavreLinear::IssueLink.create!(
          creative: @creative,
          project_link: project_link,
          linear_issue_id: "issue-resync-conflict",
          sync_state: :conflict
        )

        post "/linear/creatives/#{@creative.id}/integration/resync", as: :json

        assert_response :success
        assert conflicted.reload.dirty?,
               "resync must reopen the conflicted link so update_issue! actually pushes"
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
      # POST /linear/creatives/:creative_id/integration/secret
      # -------------------------------------------------------------------------

      test "update_secret stores the pasted signing secret on the link" do
        sign_in_as(@user)

        link = CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-secret-1",
          team_id: "team-secret-1"
        )
        assert_nil link.webhook_secret

        post "/linear/creatives/#{@creative.id}/integration/secret",
             params: { webhook_secret: "  linear-generated-value  " },
             as: :json

        assert_response :success
        assert JSON.parse(response.body)["success"]
        # Stored trimmed — pasted values often carry stray whitespace.
        assert_equal "linear-generated-value", link.reload.webhook_secret
      end

      test "update_secret rejects a blank secret" do
        sign_in_as(@user)

        CollavreLinear::ProjectLink.create!(
          creative: @creative,
          account: @account,
          linear_project_id: "proj-secret-blank",
          team_id: "team-secret-blank"
        )

        post "/linear/creatives/#{@creative.id}/integration/secret",
             params: { webhook_secret: "   " },
             as: :json

        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre_linear.errors.missing_secret"),
          JSON.parse(response.body)["error"]
      end

      test "update_secret returns not_found when no link exists" do
        sign_in_as(@user)

        post "/linear/creatives/#{@creative.id}/integration/secret",
             params: { webhook_secret: "x" }, as: :json

        assert_response :not_found
      end

      test "update_secret returns forbidden for non-admin user" do
        other = Collavre.user_class.create!(
          email: "linear-nonadmin-secret-#{SecureRandom.hex(4)}@example.com",
          name: "Non Admin Secret",
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
          linear_uid: "uid-nonadmin-secret-#{SecureRandom.hex(4)}",
          access_token: "tok-nonadmin-secret"
        )

        sign_in_as(other)

        post "/linear/creatives/#{@creative.id}/integration/secret",
             params: { webhook_secret: "x" }, as: :json

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

      # Inbound webhooks are set up by hand in Linear, so the integration flow
      # makes no webhookCreate/webhookDelete calls; tests assert that absence
      # against this endpoint.
      LINEAR_GRAPHQL_ENDPOINT = "https://api.linear.app/graphql"
    end
  end
end
