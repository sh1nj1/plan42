module CollavreSlack
  module SlackDispatchable
    extend ActiveSupport::Concern

    included do
      after_create_commit :dispatch_to_slack_channels
    end

    private

    def dispatch_to_slack_channels
      # Don't dispatch if this comment came from Slack (prevent loop)
      if instance_variable_get(:@from_slack)
        Rails.logger.info("[CollavreSlack] Skipping dispatch - comment came from Slack")
        return
      end

      # Use effective_origin since Slack links are on origin creative
      target_creative_id = creative.effective_origin.id

      return unless CollavreSlack::SlackChannelLink.where(creative_id: target_creative_id, is_active: true).exists?

      Rails.logger.info("[CollavreSlack] dispatch_to_slack_channels called for comment #{id}, creative_id=#{creative_id}, target_creative_id=#{target_creative_id}")

      links = CollavreSlack::SlackChannelLink.where(creative_id: target_creative_id, is_active: true)
      Rails.logger.info("[CollavreSlack] Found #{links.count} active Slack links")

      links.find_each do |link|
        Rails.logger.info("[CollavreSlack] Dispatching to channel #{link.channel_name} (#{link.channel_id})")
        dispatcher = CollavreSlack::SlackMessageDispatcher.new(channel_link: link)
        message_text = content.to_plain_text rescue content.to_s
        sender_name = user&.name || "Anonymous"
        dispatcher.enqueue(message: "[#{sender_name}] #{message_text}", sender: user, comment: self)
      end
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] Failed to dispatch to Slack: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end
  end
end
