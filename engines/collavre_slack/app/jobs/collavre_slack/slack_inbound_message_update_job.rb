module CollavreSlack
  class SlackInboundMessageUpdateJob < ApplicationJob
    include ErrorLoggable

    queue_as :default

    def perform(payload)
      with_slack_error_handling("SlackInboundMessageUpdateJob") do
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
