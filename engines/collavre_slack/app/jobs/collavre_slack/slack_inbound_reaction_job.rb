module CollavreSlack
  class SlackInboundReactionJob < ApplicationJob
    queue_as :default

    # SlackEventsController acks Slack with 200 the instant it enqueues this job
    # (ack-before-apply), so Slack never re-delivers the event once accepted.
    # Without a retry, a transient DB contention error would park the job and the
    # inbound reaction would be lost permanently. Only transient contention
    # retries; a real bug still raises and parks.
    retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout,
             wait: 2.seconds, attempts: 5

    # Permanent/unprocessable failures: retrying cannot help. Discard so the
    # queue self-heals rather than looping forever.
    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound
    discard_on ActiveRecord::RecordInvalid

    def perform(payload)
      data = payload.with_indifferent_access
      comment = Collavre::Comment.find_by(id: data[:comment_id])
      user = Collavre.user_class.find_by(id: data[:user_id])

      return unless comment && user

      # Check permission
      return unless comment.creative.has_permission?(user, :feedback)

      emoji = data[:emoji]
      action = data[:type].to_sym

      if action == :reaction_added
        reaction = Collavre::CommentReaction.find_or_initialize_by(
          comment: comment,
          user: user,
          emoji: emoji
        )

        if reaction.new_record?
          # Mark as coming from Slack to prevent loop
          reaction.instance_variable_set(:@from_slack, true)
          reaction.save!
          Rails.logger.info("[CollavreSlack] Created reaction from Slack: comment_id=#{comment.id}, emoji=#{emoji}, user_id=#{user.id}")
        end
      elsif action == :reaction_removed
        reaction = Collavre::CommentReaction.find_by(
          comment: comment,
          user: user,
          emoji: emoji
        )

        if reaction
          # Mark as coming from Slack to prevent loop
          reaction.instance_variable_set(:@from_slack, true)
          reaction.destroy!
          Rails.logger.info("[CollavreSlack] Removed reaction from Slack: comment_id=#{comment.id}, emoji=#{emoji}, user_id=#{user.id}")
        end
      end
    end
  end
end
