# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class OutboundSyncJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    # ---------------------------------------------------------------------------
    # A simple no-op exporter stub
    # ---------------------------------------------------------------------------
    class NoopExporter
      def initialize(_creative); end
      def sync!; end
    end

    # ---------------------------------------------------------------------------
    # Setup / teardown
    # ---------------------------------------------------------------------------

    def setup
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = Collavre.user_class.create!(
        email: "job-test-#{SecureRandom.hex(4)}@example.com",
        name: "Job Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      @creative = Collavre::Creative.create!(
        description: "<p>Job Test Creative</p>",
        user: @user
      )
    end

    def teardown
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    # ---------------------------------------------------------------------------
    # Enqueueing
    # ---------------------------------------------------------------------------

    test "perform_later enqueues the job" do
      assert_enqueued_with(job: CollavreLinear::OutboundSyncJob, args: [ @creative.id ]) do
        CollavreLinear::OutboundSyncJob.perform_later(@creative.id)
      end
    end

    # ---------------------------------------------------------------------------
    # perform delegates to CreativeExporter
    # ---------------------------------------------------------------------------

    test "perform calls CreativeExporter#sync! for the given creative" do
      synced_creative_id = nil

      stub_exporter_class = Class.new do
        attr_reader :creative
        def initialize(c)
          @creative = c
        end
        def sync!
          # nothing
        end
      end

      # Capture which creative was handed to the exporter
      CollavreLinear::CreativeExporter.stub(:new, lambda { |c|
        synced_creative_id = c.id
        stub_exporter_class.new(c)
      }) do
        CollavreLinear::OutboundSyncJob.perform_now(@creative.id)
      end

      assert_equal @creative.id, synced_creative_id,
        "perform must call CreativeExporter.new with the correct creative"
    end

    # ---------------------------------------------------------------------------
    # Missing creative — silent skip
    # ---------------------------------------------------------------------------

    test "perform is silent when creative does not exist" do
      assert_nothing_raised do
        CollavreLinear::OutboundSyncJob.perform_now(-999)
      end
    end

    # ---------------------------------------------------------------------------
    # Ordering: a child whose job runs before its parent's export must NOT be
    # created as a top-level Linear issue — it defers until the parent lands.
    # ---------------------------------------------------------------------------

    test "child job running before parent export defers instead of creating a top-level issue" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-order-#{SecureRandom.hex(4)}",
        access_token: "tok-order"
      )
      CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  account,
        linear_project_id: "proj-order",
        team_id:           "team-order"
      )
      child = Collavre::Creative.new(
        description: "<p>Child</p>", user: @user, parent: @creative
      )
      child.skip_linear_sync = true
      child.save!

      created = []
      fake_client = Class.new do
        define_method(:create_issue) do |**kw|
          created << kw
          { id: "iss-#{created.size}", identifier: "ENG-#{created.size}" }
        end
        def update_issue(id, **_) = { id: id, identifier: "ENG-0" }
      end.new

      # Child job runs FIRST — parent has no Linear issue yet. It must NOT
      # create a Linear issue (would be top-level); it re-enqueues instead.
      CollavreLinear::Client.stub(:new, fake_client) do
        assert_enqueued_with(job: CollavreLinear::OutboundSyncJob, args: [ child.id ]) do
          CollavreLinear::OutboundSyncJob.perform_now(child.id)
        end
      end

      assert_empty created, "child must not create a top-level issue before its parent exists"
      assert_nil CollavreLinear::IssueLink.find_by(creative_id: child.id),
        "no IssueLink should exist for the deferred child"

      # Now the parent exports, then the retried child nests under it.
      CollavreLinear::Client.stub(:new, fake_client) do
        CollavreLinear::OutboundSyncJob.perform_now(@creative.id)
        CollavreLinear::OutboundSyncJob.perform_now(child.id)
      end

      child_link = CollavreLinear::IssueLink.find_by(creative_id: child.id)
      assert_not_nil child_link, "child must be exported once the parent exists"
      parent_link = CollavreLinear::IssueLink.find_by(creative_id: @creative.id)
      child_call = created.last
      assert_equal parent_link.linear_issue_id, child_call[:parent_id],
        "child must be nested under the parent's Linear issue, not top-level"
    end

    # ---------------------------------------------------------------------------
    # Idempotent single-create across repeated performs
    # ---------------------------------------------------------------------------

    test "repeated performs create exactly one IssueLink and call create_issue exactly once" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-job-lock-#{SecureRandom.hex(4)}",
        access_token: "tok-job"
      )
      _project_link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  account,
        linear_project_id: "proj-lock",
        team_id:           "team-lock"
      )

      # Track how many create_issue calls are made across both performs.
      create_count = 0
      fake_client = Class.new do
        define_method(:create_issue) do |**_|
          create_count += 1
          { id: "iss-lock-#{create_count}", identifier: "ENG-#{create_count}" }
        end
        def update_issue(id, **_) = { id: id, identifier: "ENG-0" }
      end.new

      # NOTE: DB-level with_lock serialization under true thread concurrency is not
      # unit-tested here because the test DB / transactional fixtures don't exercise
      # real row-lock contention.  This test verifies create-idempotency via
      # IssueLink reload: the second perform sees the IssueLink written by the first
      # and must take the update path (or skip due to dirty-tracking), never calling
      # create_issue a second time.  Do NOT attempt a flaky multi-threaded test.
      CollavreLinear::Client.stub(:new, fake_client) do
        CollavreLinear::OutboundSyncJob.perform_now(@creative.id)
        CollavreLinear::OutboundSyncJob.perform_now(@creative.id)
      end

      assert_equal 1, create_count,
        "create_issue must be called exactly once even across repeated performs"

      links = CollavreLinear::IssueLink.where(creative_id: @creative.id)
      assert_equal 1, links.count,
        "exactly one IssueLink must exist after repeated performs"
    end
  end
end
