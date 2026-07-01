# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  # Task 12 — keystone round-trip integration test.
  #
  # Proves the bidirectional sync loop is CLOSED and ECHO-FREE end to end:
  #
  #   (a) OUTBOUND: creating a Creative inside a linked subtree enqueues an
  #       OutboundSyncJob whose execution drives the GraphQL client's issueCreate
  #       mutation (via CreativeExporter#create_issue).
  #
  #   (b) ECHO SUPPRESSION: a Linear webhook echoing OUR OWN app actor.id is
  #       acked (200) but applies NO local change and enqueues NO inbound job.
  #
  #   (c) INBOUND (human): a webhook from a HUMAN actor updates the Creative AND
  #       enqueues NO outbound job — the inbound applier sets skip_linear_sync so
  #       the resulting after_commit does not re-export (no return echo).
  #
  # These scenarios exercise the real controller → EchoGuard → InboundApplyJob →
  # InboundApplier path (b, c) and the real observer → OutboundSyncJob →
  # CreativeExporter → Client path (a), stubbing only the network boundary
  # (CollavreLinear::Client) exactly as the existing exporter test does.
  class RoundTripTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    # -------------------------------------------------------------------------
    # Network-boundary stub — conforms to Client's public interface, records
    # calls, performs no I/O. Mirrors CreativeExporterTest::FakeClient.
    # -------------------------------------------------------------------------
    class FakeClient
      attr_reader :create_calls, :update_calls

      def initialize(create_response: { id: "iss-rt-new", identifier: "ENG-RT" })
        @create_response = create_response
        @create_calls    = []
        @update_calls    = []
      end

      # Backs the ISSUE_CREATE / issueCreate GraphQL mutation.
      def create_issue(**kwargs)
        @create_calls << kwargs
        @create_response
      end

      def update_issue(id, **kwargs)
        @update_calls << kwargs.merge(_id: id)
        @create_response
      end
    end

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = Collavre.user_class.create!(
        email: "round-trip-#{SecureRandom.hex(4)}@example.com",
        name: "Round Trip",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      # The app actor id stored on the account is what EchoGuard compares webhook
      # actor.id against to detect our own bounced-back events.
      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-rt-#{SecureRandom.hex(4)}",
        access_token: "tok-rt",
        app_actor_id: "app-actor-rt-#{SecureRandom.hex(4)}"
      )

      # Root creative carries the ProjectLink -> defines the linked subtree.
      @root_creative = Collavre::Creative.new(description: "<p>RT Root</p>", user: @user)
      @root_creative.skip_linear_sync = true
      @root_creative.save!

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @root_creative,
        account:  @account,
        linear_project_id: "proj-rt",
        team_id:           "team-rt"
      )
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    # -------------------------------------------------------------------------
    # Helpers (webhook signing — mirrors WebhooksControllerTest)
    # -------------------------------------------------------------------------

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

    # A linked child Creative already synced to Linear (has an IssueLink). Built
    # with skip_linear_sync so construction doesn't fire an outbound job.
    def linked_child(linear_issue_id:, description: "<p>Original title</p>")
      creative = Collavre::Creative.new(
        description: description,
        user: @user,
        parent: @root_creative
      )
      creative.skip_linear_sync = true
      creative.save!

      link = CollavreLinear::IssueLink.create!(
        creative:          creative,
        project_link:      @project_link,
        linear_issue_id:   linear_issue_id,
        remote_updated_at: 1.hour.ago,
        sync_state:        :synced
      )
      [ creative, link ]
    end

    # -------------------------------------------------------------------------
    # (a) OUTBOUND — Creative create in a linked subtree drives issueCreate.
    # -------------------------------------------------------------------------

    test "(a) creating a Creative in a linked subtree enqueues OutboundSyncJob that calls issueCreate" do
      child = nil

      # In a real linked subtree the root has already been exported to Linear;
      # give it its issue so the new child nests under it rather than deferring
      # on the parent-ordering guard.
      CollavreLinear::IssueLink.create!(
        creative:          @root_creative,
        project_link:      @project_link,
        linear_issue_id:   "iss-rt-root",
        remote_updated_at: 1.hour.ago,
        sync_state:        :synced
      )

      # The observer's after_commit enqueues exactly one OutboundSyncJob.
      assert_enqueued_jobs 1, only: CollavreLinear::OutboundSyncJob do
        child = Collavre::Creative.create!(
          description: "<p>RT outbound child</p>",
          user: @user,
          parent: @root_creative
        )
      end
      assert_enqueued_with(job: CollavreLinear::OutboundSyncJob, args: [ child.id ])

      # Perform the enqueued job with the network stubbed: proves the outbound
      # path reaches the GraphQL client's issueCreate (create_issue) mutation.
      fake_client = FakeClient.new
      CollavreLinear::Client.stub(:new, fake_client) do
        perform_enqueued_jobs(only: CollavreLinear::OutboundSyncJob)
      end

      assert_equal 1, fake_client.create_calls.size,
        "outbound path must call the client's issueCreate (create_issue) exactly once"
      call = fake_client.create_calls.first
      assert_equal "team-rt", call[:team_id]
      assert_equal "proj-rt", call[:project_id]

      # And it persisted the IssueLink from the create response — loop endpoint wired.
      link = CollavreLinear::IssueLink.find_by(creative_id: child.id)
      assert_not_nil link, "create must persist an IssueLink"
      assert_equal "iss-rt-new", link.linear_issue_id
    end

    # -------------------------------------------------------------------------
    # (b) ECHO SUPPRESSION — our own actor bounces back → no-op.
    # -------------------------------------------------------------------------

    test "(b) webhook echoing OUR OWN actor.id applies no change and enqueues no job" do
      creative, link = linked_child(linear_issue_id: "iss-rt-echo")
      original_description = creative.reload.description
      original_updated_at  = link.remote_updated_at

      payload = {
        action: "update",
        type: "Issue",
        actor: { id: @account.app_actor_id }, # OUR app actor → echo
        webhookTimestamp: (Time.now.to_f * 1000).to_i,
        data: {
          id: "iss-rt-echo",
          teamId: "team-rt",
          title: "Echoed title should NOT be applied",
          updatedAt: Time.current.iso8601
        },
        updatedFrom: { title: "old" }
      }.to_json

      # No inbound job enqueued: EchoGuard short-circuits before InboundApplyJob.
      assert_no_enqueued_jobs do
        post_webhook(payload, sign(payload))
      end

      # Linear still gets a 200 ack so it stops retrying.
      assert_response :ok

      # And nothing changed locally.
      assert_equal original_description, creative.reload.description,
        "echoed webhook must not mutate the Creative"
      assert_equal original_updated_at.to_i, link.reload.remote_updated_at.to_i,
        "echoed webhook must not advance remote_updated_at"
    end

    # -------------------------------------------------------------------------
    # (c) INBOUND (human) — updates Creative, no re-export echo.
    # -------------------------------------------------------------------------

    test "(c) webhook from a HUMAN actor updates the Creative and enqueues no outbound job" do
      creative, _link = linked_child(linear_issue_id: "iss-rt-human")

      payload = {
        action: "update",
        type: "Issue",
        actor: { id: "human-actor-1" }, # NOT our app actor
        webhookTimestamp: (Time.now.to_f * 1000).to_i,
        data: {
          id: "iss-rt-human",
          teamId: "team-rt",
          title: "Human updated title",
          priority: 2,
          updatedAt: Time.current.iso8601
        },
        updatedFrom: { title: "old title" }
      }.to_json

      # The controller enqueues an InboundApplyJob (human, not echo).
      assert_enqueued_with(job: CollavreLinear::InboundApplyJob) do
        post_webhook(payload, sign(payload))
      end
      assert_response :ok

      # Performing the inbound job must apply the change AND must NOT enqueue an
      # OutboundSyncJob — the applier sets skip_linear_sync, closing the loop
      # without a return echo.
      assert_no_enqueued_jobs(only: CollavreLinear::OutboundSyncJob) do
        perform_enqueued_jobs(only: CollavreLinear::InboundApplyJob)
      end

      assert_includes creative.reload.description, "Human updated title",
        "inbound human update must be applied to the Creative"
    end
  end
end
