# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class OutboundArchiveJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    def setup
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = Collavre.user_class.create!(
        email: "archive-job-#{SecureRandom.hex(4)}@example.com",
        name: "Archive Job Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-archive-#{SecureRandom.hex(4)}",
        access_token: "tok-archive"
      )
    end

    def teardown
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    # ---------------------------------------------------------------------------
    # Enqueueing
    # ---------------------------------------------------------------------------

    test "perform_later enqueues the job with linear_issue_id and account_id" do
      assert_enqueued_with(
        job: CollavreLinear::OutboundArchiveJob,
        args: ["iss-archive-1", @account.id]
      ) do
        CollavreLinear::OutboundArchiveJob.perform_later("iss-archive-1", @account.id)
      end
    end

    # ---------------------------------------------------------------------------
    # perform calls client.archive_issue
    # ---------------------------------------------------------------------------

    test "perform calls client.archive_issue with the linear_issue_id" do
      archived_id = nil

      fake_client = Object.new
      fake_client.define_singleton_method(:archive_issue) do |id|
        archived_id = id
        true
      end

      CollavreLinear::Client.stub(:new, fake_client) do
        CollavreLinear::OutboundArchiveJob.perform_now("iss-to-delete", @account.id)
      end

      assert_equal "iss-to-delete", archived_id,
        "OutboundArchiveJob must call client.archive_issue with the captured linear_issue_id"
    end

    # ---------------------------------------------------------------------------
    # Missing account — silent skip
    # ---------------------------------------------------------------------------

    test "perform is silent when account does not exist" do
      assert_nothing_raised do
        CollavreLinear::OutboundArchiveJob.perform_now("iss-gone", -999)
      end
    end
  end
end
