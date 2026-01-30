module CollavreSlack
  class SlackChannelSyncJob < ApplicationJob
    queue_as :default

    def perform(slack_channel_link_id)
      link = SlackChannelLink.find(slack_channel_link_id)
      client = SlackClient.new(access_token: link.slack_account.access_token)
      oldest = link.last_synced_at&.to_f
      response = client.list_messages(channel: link.channel_id, oldest: oldest)
      return unless response[:ok]

      messages = Array(response[:messages]).reverse
      messages.each do |message|
        next if message[:subtype].present?

        user = link.slack_account.slack_user_mappings.find_by(slack_user_id: message[:user])&.collavre_user
        user ||= link.created_by
        next unless user

        content = MentionMapping.from_slack(message[:text].to_s, link.slack_account)
        SlackInboundMessageJob.perform_later({ creative_id: link.creative_id, user_id: user.id, content: content })
      end

      link.update!(last_synced_at: Time.current)
    end
  end
end
