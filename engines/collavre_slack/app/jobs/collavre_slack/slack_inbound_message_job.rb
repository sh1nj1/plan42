module CollavreSlack
  class SlackInboundMessageJob < ApplicationJob
    queue_as :default

    def perform(payload)
      data = payload.with_indifferent_access
      creative = Collavre::Creative.find(data[:creative_id])
      user = Collavre.user_class.find_by(id: data[:user_id])
      return unless creative && user

      return unless creative.has_permission?(user, :feedback)

      comment = Collavre::Comment.new(
        creative: creative,
        user: user,
        content: data[:content]
      )

      # Mark this comment as coming from Slack to prevent loop
      comment.instance_variable_set(:@from_slack, true)

      response = Collavre::Comments::CommandProcessor.new(comment: comment, user: user).call
      comment.content = "#{comment.content}\n\n#{response}" if response.present?
      comment.save!

      # Create link between Slack message and comment for reaction sync
      if data[:slack_channel_link_id].present? && data[:slack_message_ts].present?
        SlackCommentLink.create!(
          comment: comment,
          slack_channel_link_id: data[:slack_channel_link_id],
          message_ts: data[:slack_message_ts]
        )
      end
    end
  end
end
