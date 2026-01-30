module CollavreSlack
  class SlackInboundMessageDeleteJob < ApplicationJob
    queue_as :default

    def perform(payload)
      data = payload.with_indifferent_access
      comment = Collavre::Comment.find_by(id: data[:comment_id])

      if comment
        # Mark as coming from Slack to prevent loop
        comment.instance_variable_set(:@from_slack, true)
        comment.destroy!
        Rails.logger.info("[CollavreSlack] Deleted comment #{data[:comment_id]} from Slack deletion")
      end

      # Clean up the comment link record
      if data[:slack_comment_link_id].present?
        SlackCommentLink.find_by(id: data[:slack_comment_link_id])&.destroy
      end
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] SlackInboundMessageDeleteJob error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end
  end
end
