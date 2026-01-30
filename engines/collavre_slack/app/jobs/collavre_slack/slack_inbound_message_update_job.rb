module CollavreSlack
  class SlackInboundMessageUpdateJob < ApplicationJob
    queue_as :default

    def perform(payload)
      data = payload.with_indifferent_access
      comment = Collavre::Comment.find_by(id: data[:comment_id])
      return unless comment

      new_content = data[:content]
      return if new_content.blank?

      # Mark as coming from Slack to prevent loop
      comment.instance_variable_set(:@from_slack, true)
      comment.update!(content: new_content)

      Rails.logger.info("[CollavreSlack] Updated comment #{comment.id} from Slack edit")
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] SlackInboundMessageUpdateJob error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end
  end
end
