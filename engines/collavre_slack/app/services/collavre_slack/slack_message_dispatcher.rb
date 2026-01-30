module CollavreSlack
  class SlackMessageDispatcher
    def initialize(channel_link:)
      @channel_link = channel_link
    end

    def enqueue(message:, sender: nil)
      formatted = MentionMapping.to_slack(message.to_s, channel_link.slack_account)
      log = SlackMessageLog.create!(
        slack_channel_link: channel_link,
        sender: sender,
        message: formatted,
        status: "queued"
      )
      SlackMessageJob.perform_later(log.id)
      log
    end

    private

    attr_reader :channel_link
  end
end
