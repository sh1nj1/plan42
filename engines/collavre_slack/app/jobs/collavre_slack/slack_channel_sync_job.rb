module CollavreSlack
  class SlackChannelSyncJob < ApplicationJob
    queue_as :default

    def perform(slack_channel_link_id)
      link = SlackChannelLink.find(slack_channel_link_id)
      client = SlackClient.new(access_token: link.slack_account.access_token)
      oldest = link.last_synced_at&.to_f
      newest_ts = nil
      cursor = nil

      loop do
        response = client.list_messages(channel: link.channel_id, oldest: oldest, cursor: cursor)
        break unless response[:ok]

        messages = Array(response[:messages])
        break if messages.empty?

        # Track the newest message timestamp (messages are returned newest first)
        newest_ts ||= messages.first[:ts]

        # Process messages in chronological order (oldest first)
        messages.reverse.each do |message|
          next if message[:subtype].present?

          user = link.slack_account.slack_user_mappings.find_by(slack_user_id: message[:user])&.collavre_user
          user ||= link.created_by
          next unless user

          content = MentionMapping.from_slack(message[:text].to_s, link.slack_account)
          SlackInboundMessageJob.perform_later({ creative_id: link.creative_id, user_id: user.id, content: content })
        end

        # Check for more pages
        cursor = response.dig(:response_metadata, :next_cursor)
        break if cursor.blank?
      end

      # Update last_synced_at to the newest processed message timestamp
      if newest_ts.present?
        link.update!(last_synced_at: Time.at(newest_ts.to_f))
      end
    end
  end
end
