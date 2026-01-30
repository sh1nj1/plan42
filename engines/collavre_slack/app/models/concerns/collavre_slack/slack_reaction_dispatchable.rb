module CollavreSlack
  module SlackReactionDispatchable
    extend ActiveSupport::Concern

    included do
      after_create_commit :dispatch_reaction_to_slack
      after_destroy_commit :remove_reaction_from_slack
    end

    private

    def dispatch_reaction_to_slack
      return if instance_variable_get(:@from_slack)
      return unless comment_id.present?

      # Check if comment has any Slack links
      return unless CollavreSlack::SlackCommentLink.exists?(comment_id: comment_id)

      Rails.logger.info("[CollavreSlack] Dispatching reaction add: comment_id=#{comment_id}, emoji=#{emoji}")
      CollavreSlack::SlackReactionJob.perform_later(
        comment_id: comment_id,
        emoji: emoji,
        action: :add,
        user_id: user_id
      )
    end

    def remove_reaction_from_slack
      return if instance_variable_get(:@from_slack)
      return unless comment_id.present?

      # Check if comment has any Slack links
      return unless CollavreSlack::SlackCommentLink.exists?(comment_id: comment_id)

      Rails.logger.info("[CollavreSlack] Dispatching reaction remove: comment_id=#{comment_id}, emoji=#{emoji}")
      CollavreSlack::SlackReactionJob.perform_later(
        comment_id: comment_id,
        emoji: emoji,
        action: :remove,
        user_id: user_id
      )
    end
  end
end
