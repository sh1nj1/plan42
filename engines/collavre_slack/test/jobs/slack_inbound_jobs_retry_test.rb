require_relative "../test_helper"

module CollavreSlack
  # The Slack events controller acks Slack with 200 the instant it enqueues an
  # inbound job (ack-before-apply). Slack therefore never re-delivers the event,
  # so each inbound job must self-heal: retry transient DB contention and discard
  # permanently-unprocessable payloads instead of parking (which loses the event
  # forever).
  class SlackInboundJobsRetryTest < ActiveSupport::TestCase
    INBOUND_JOBS = [
      SlackInboundMessageJob,
      SlackInboundReactionJob,
      SlackInboundMessageUpdateJob,
      SlackInboundMessageDeleteJob
    ].freeze

    TRANSIENT_ERRORS = %w[
      ActiveRecord::Deadlocked
      ActiveRecord::LockWaitTimeout
    ].freeze

    PERMANENT_ERRORS = %w[
      ActiveJob::DeserializationError
      ActiveRecord::RecordNotFound
      ActiveRecord::RecordInvalid
    ].freeze

    test "every inbound job registers retry and discard handlers" do
      INBOUND_JOBS.each do |job|
        handled = job.rescue_handlers.map(&:first)
        (TRANSIENT_ERRORS + PERMANENT_ERRORS).each do |error|
          assert_includes handled, error,
            "#{job} must handle #{error} so acked-but-crashed events are not lost"
        end
      end
    end

    test "message job discards a payload whose creative no longer exists" do
      payload = {
        creative_id: -1,
        user_id: nil,
        content: "orphaned",
        slack_channel_link_id: nil,
        slack_message_ts: "1234567890.123456"
      }

      # discard_on ActiveRecord::RecordNotFound swallows the error rather than
      # re-raising, so perform_now returns without blowing up.
      assert_nothing_raised do
        SlackInboundMessageJob.perform_now(payload)
      end
    end
  end
end
