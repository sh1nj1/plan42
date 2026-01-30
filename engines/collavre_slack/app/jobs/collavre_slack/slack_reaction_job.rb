module CollavreSlack
  class SlackReactionJob < ApplicationJob
    queue_as :default

    def perform(comment_id:, emoji:, action:, user_id: nil)
      Rails.logger.info("[CollavreSlack] SlackReactionJob performing: comment_id=#{comment_id}, emoji=#{emoji.inspect}, action=#{action}")

      comment_links = SlackCommentLink.where(comment_id: comment_id)
      Rails.logger.info("[CollavreSlack] Found #{comment_links.count} comment links")
      return if comment_links.empty?

      # Convert emoji to Slack format (remove colons if present, handle common mappings)
      slack_emoji = normalize_emoji_for_slack(emoji)
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

    private

    def normalize_emoji_for_slack(emoji)
      # Remove surrounding colons if present (e.g., ":thumbsup:" -> "thumbsup")
      normalized = emoji.to_s.gsub(/^:|:$/, "")

      # Common emoji name mappings from Unicode to Slack names
      emoji_map = {
        "\u{1F44D}" => "thumbsup",
        "\u{1F44E}" => "thumbsdown",
        "\u{2764}" => "heart",
        "\u{1F600}" => "grinning",
        "\u{1F602}" => "joy",
        "\u{1F44F}" => "clap",
        "\u{1F389}" => "tada",
        "\u{1F440}" => "eyes",
        "\u{1F64F}" => "pray",
        "\u{1F525}" => "fire",
        "\u{2705}" => "white_check_mark",
        "\u{274C}" => "x",
        "\u{1F680}" => "rocket"
      }

      emoji_map[normalized] || normalized
    end
  end
end
