module CollavreSlack
  class SlackInboundMessageUpdateJob < ApplicationJob
    include ErrorLoggable

    queue_as :default

    # SlackEventsController acks Slack with 200 the instant it enqueues this job
    # (ack-before-apply), so Slack never re-delivers the event once accepted.
    # Without a retry, a transient DB contention error would park the job and the
    # inbound edit would be lost permanently. Only transient contention retries.
    retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout,
             wait: 2.seconds, attempts: 5

    # Permanent/unprocessable failures: retrying cannot help. Discard so the
    # queue self-heals rather than looping forever.
    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound
    discard_on ActiveRecord::RecordInvalid

    def perform(payload)
      # reraise so transient errors reach retry_on and permanent ones reach
      # discard_on; the concern still logs before re-raising.
      with_slack_error_handling("SlackInboundMessageUpdateJob", reraise: true) do
        data = payload.with_indifferent_access
        comment = Collavre::Comment.find_by(id: data[:comment_id])
        return unless comment

        new_content = data[:content]
        return if new_content.blank?

        # Mark as coming from Slack to prevent loop
        comment.instance_variable_set(:@from_slack, true)
        comment.update!(content: new_content)

        Rails.logger.info("[CollavreSlack] Updated comment #{comment.id} from Slack edit")
      end
    end
  end
end
