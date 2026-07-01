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
      assert_enqueued_with(job: CollavreLinear::OutboundSyncJob, args: [@creative.id]) do
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
    # Concurrent-perform — with_lock guard (no double-create)
    # ---------------------------------------------------------------------------

    test "concurrent performs do not double-create the IssueLink" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-job-lock-#{SecureRandom.hex(4)}",
        access_token: "tok-job"
      )
      project_link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  account,
        linear_project_id: "proj-lock",
        team_id:           "team-lock"
      )

      # Track how many create_issue calls are made.
      create_count = 0
      fake_client = Class.new do
        define_method(:create_issue) do |**_|
          create_count += 1
          { id: "iss-lock-#{create_count}", identifier: "ENG-#{create_count}" }
        end
        def update_issue(id, **_) = { id: id, identifier: "ENG-0" }
      end.new

      CollavreLinear::Client.stub(:new, fake_client) do
        # Simulate two concurrent performs: run both sequentially with the same
        # creative — the with_lock on the creative row in the job means the second
        # one sees the IssueLink created by the first and calls update_issue
        # (or skips due to dirty-tracking), never create_issue a second time.
        CollavreLinear::OutboundSyncJob.perform_now(@creative.id)
        CollavreLinear::OutboundSyncJob.perform_now(@creative.id)
      end

      assert_equal 1, create_count,
        "create_issue must be called exactly once even with concurrent performs"

      links = CollavreLinear::IssueLink.where(creative_id: @creative.id)
      assert_equal 1, links.count,
        "exactly one IssueLink must exist after concurrent performs"
    end
  end
end
