module CollavreSlack
  class SlackReactionJob < ApplicationJob
    queue_as :default

    def perform(comment_id:, emoji:, action:, user_id: nil)
      Rails.logger.info("[CollavreSlack] SlackReactionJob performing: comment_id=#{comment_id}, emoji=#{emoji.inspect}, action=#{action}")

      comment_links = SlackCommentLink.where(comment_id: comment_id)
      Rails.logger.info("[CollavreSlack] Found #{comment_links.count} comment links")
      return if comment_links.empty?

      # Convert emoji to Slack format (remove colons if present, handle common mappings)
      slack_emoji = EmojiMapping.to_slack(emoji)
      Rails.logger.info("[CollavreSlack] Normalized emoji: #{emoji.inspect} -> #{slack_emoji.inspect}")

      comment_links.each do |link|
        channel_link = link.slack_channel_link
        client = SlackClient.new(access_token: channel_link.slack_account.access_token)

        response = if action == :add
          client.add_reaction(
            channel: channel_link.channel_id,
            timestamp: link.message_ts,
            name: slack_emoji
          )
        else
          client.remove_reaction(
            channel: channel_link.channel_id,
            timestamp: link.message_ts,
            name: slack_emoji
          )
        end

        if response[:ok]
          Rails.logger.info("[CollavreSlack] Reaction #{action} successful for channel=#{channel_link.channel_id}, ts=#{link.message_ts}")
        else
          # already_reacted and no_reaction are not errors
          unless %w[already_reacted no_reaction].include?(response[:error])
            Rails.logger.warn("[CollavreSlack] Reaction #{action} failed: #{response[:error]}")
          end
        end
      end
    end
  end
end
