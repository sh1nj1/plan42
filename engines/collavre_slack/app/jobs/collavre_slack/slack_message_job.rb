module CollavreSlack
  class SlackMessageJob < ApplicationJob
    queue_as :default

    def perform(slack_message_log_id)
      Rails.logger.info("[CollavreSlack] SlackMessageJob performing for log_id=#{slack_message_log_id}")
      log = SlackMessageLog.find(slack_message_log_id)
      link = log.slack_channel_link
      Rails.logger.info("[CollavreSlack] Posting to channel=#{link.channel_id}, message=#{log.message.truncate(50)}")

      client = SlackClient.new(access_token: link.slack_account.access_token)
      response = client.post_message(channel: link.channel_id, text: log.message)
      Rails.logger.info("[CollavreSlack] Slack API response: ok=#{response[:ok]}, error=#{response[:error]}")

      if response[:status] == 429
        retry_after = response[:headers].to_h["retry-after"].to_i
        retry_after = 5 if retry_after <= 0
        log.update!(status: "rate_limited", error_message: "rate_limited")
        self.class.set(wait: retry_after.seconds).perform_later(log.id)
        return
      end

      if response[:ok]
        log.update!(status: "sent", message_ts: response[:ts])
        Rails.logger.info("[CollavreSlack] Message sent successfully, ts=#{response[:ts]}")

        # Create link between comment and Slack message for reaction sync
        if log.comment_id.present?
          SlackCommentLink.create!(
            comment_id: log.comment_id,
            slack_channel_link_id: link.id,
            message_ts: response[:ts]
          )
        end
      else
        log.update!(status: "failed", error_message: response[:error])
        Rails.logger.error("[CollavreSlack] Failed to send message: #{response[:error]}")
      end
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] SlackMessageJob error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      log&.update!(status: "failed", error_message: e.message)
      raise
    end
  end
end
