module CollavreSlack
  class SlackMessageUpdateJob < ApplicationJob
    include ErrorLoggable

    queue_as :default

    def perform(slack_comment_link_id:, message:)
      with_slack_error_handling("SlackMessageUpdateJob") do
        Rails.logger.info("[CollavreSlack] SlackMessageUpdateJob performing for link_id=#{slack_comment_link_id}")

        comment_link = SlackCommentLink.find_by(id: slack_comment_link_id)
        return unless comment_link

        channel_link = comment_link.slack_channel_link
        return unless channel_link

        formatted_message = MentionMapping.to_slack(message, channel_link.slack_account)

        client = SlackClient.new(access_token: channel_link.slack_account.access_token)
        response = client.update_message(
          channel: channel_link.channel_id,
          timestamp: comment_link.message_ts,
          text: formatted_message
        )

        if response[:ok]
          Rails.logger.info("[CollavreSlack] Message updated successfully, ts=#{comment_link.message_ts}")
        else
          Rails.logger.error("[CollavreSlack] Failed to update message: #{response[:error]}")
        end
      end
    end
  end
end
