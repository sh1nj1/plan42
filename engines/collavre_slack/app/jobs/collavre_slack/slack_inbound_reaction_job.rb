module CollavreSlack
  class SlackInboundReactionJob < ApplicationJob
    queue_as :default

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
