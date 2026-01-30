module CollavreSlack
  class SlackMessageJob < ApplicationJob
    queue_as :default

    def perform(slack_message_log_id)
      log = SlackMessageLog.find(slack_message_log_id)
      link = log.slack_channel_link
      client = SlackClient.new(access_token: link.slack_account.access_token)

      response = client.post_message(channel: link.channel_id, text: log.message)
      if response[:status] == 429
        retry_after = response[:headers].to_h["retry-after"].to_i
        retry_after = 5 if retry_after <= 0
        log.update!(status: "rate_limited", error_message: "rate_limited")
        self.class.set(wait: retry_after.seconds).perform_later(log.id)
        return
      end

      if response[:ok]
        log.update!(status: "sent", message_ts: response[:ts])
      else
        log.update!(status: "failed", error_message: response[:error])
      end
    rescue StandardError => e
      log.update!(status: "failed", error_message: e.message)
      raise
    end
  end
end
