module CollavreSlack
  class SlackMessageDeleteJob < ApplicationJob
    include ErrorLoggable

    queue_as :default

    def perform(slack_channel_link_id:, message_ts:)
      with_slack_error_handling("SlackMessageDeleteJob") do
        Rails.logger.info("[CollavreSlack] SlackMessageDeleteJob performing for channel_link_id=#{slack_channel_link_id}, ts=#{message_ts}")

        channel_link = SlackChannelLink.find_by(id: slack_channel_link_id)
        return unless channel_link

        client = SlackClient.new(access_token: channel_link.slack_account.access_token)
        response = client.delete_message(
          channel: channel_link.channel_id,
          timestamp: message_ts
        )

        if response[:ok]
          Rails.logger.info("[CollavreSlack] Message deleted successfully, ts=#{message_ts}")
        else
          # message_not_found is not an error - message may have been deleted on Slack already
          unless response[:error] == "message_not_found"
            Rails.logger.error("[CollavreSlack] Failed to delete message: #{response[:error]}")
          end
        end
      end
    end
  end
end
