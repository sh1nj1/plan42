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
      return "thumbsup" if emoji.blank?

      str = emoji.to_s.strip

      # Remove surrounding colons if present (e.g., ":thumbsup:" -> "thumbsup")
      str = str.gsub(/^:+|:+$/, "")

      # Common emoji name mappings from Unicode to Slack names
      emoji_map = {
        # Thumbs
        "\u{1F44D}" => "thumbsup", "👍" => "thumbsup",
        "\u{1F44E}" => "thumbsdown", "👎" => "thumbsdown",
        # Hearts
        "\u{2764}" => "heart", "❤️" => "heart", "❤" => "heart",
        "\u{1F499}" => "blue_heart", "💙" => "blue_heart",
        "\u{1F49A}" => "green_heart", "💚" => "green_heart",
        "\u{1F49B}" => "yellow_heart", "💛" => "yellow_heart",
        # Faces
        "\u{1F600}" => "grinning", "😀" => "grinning",
        "\u{1F603}" => "smiley", "😃" => "smiley",
        "\u{1F604}" => "smile", "😄" => "smile",
        "\u{1F601}" => "grin", "😁" => "grin",
        "\u{1F602}" => "joy", "😂" => "joy",
        "\u{1F605}" => "sweat_smile", "😅" => "sweat_smile",
        "\u{1F606}" => "laughing", "😆" => "laughing",
        "\u{1F609}" => "wink", "😉" => "wink",
        "\u{1F60A}" => "blush", "😊" => "blush",
        "\u{1F60D}" => "heart_eyes", "😍" => "heart_eyes",
        "\u{1F914}" => "thinking_face", "🤔" => "thinking_face",
        "\u{1F622}" => "cry", "😢" => "cry",
        "\u{1F62D}" => "sob", "😭" => "sob",
        "\u{1F621}" => "rage", "😡" => "rage",
        "\u{1F620}" => "angry", "😠" => "angry",
        # Hands
        "\u{1F44F}" => "clap", "👏" => "clap",
        "\u{1F64C}" => "raised_hands", "🙌" => "raised_hands",
        "\u{1F64F}" => "pray", "🙏" => "pray",
        "\u{1F44B}" => "wave", "👋" => "wave",
        "\u{1F44C}" => "ok_hand", "👌" => "ok_hand",
        "\u{270C}" => "v", "✌️" => "v", "✌" => "v",
        # Objects
        "\u{1F389}" => "tada", "🎉" => "tada",
        "\u{1F525}" => "fire", "🔥" => "fire",
        "\u{1F680}" => "rocket", "🚀" => "rocket",
        "\u{2B50}" => "star", "⭐" => "star",
        "\u{1F4AF}" => "100", "💯" => "100",
        "\u{1F440}" => "eyes", "👀" => "eyes",
        # Symbols
        "\u{2705}" => "white_check_mark", "✅" => "white_check_mark",
        "\u{274C}" => "x", "❌" => "x",
        "\u{2714}" => "heavy_check_mark", "✔️" => "heavy_check_mark", "✔" => "heavy_check_mark",
        "\u{26A0}" => "warning", "⚠️" => "warning", "⚠" => "warning",
        "\u{2753}" => "question", "❓" => "question",
        "\u{2757}" => "exclamation", "❗" => "exclamation",
        # +1/-1 aliases
        "+1" => "thumbsup",
        "-1" => "thumbsdown"
      }

      result = emoji_map[str] || str

      # If still contains non-ASCII, it might be an unmapped emoji - log it
      if result.match?(/[^\x00-\x7F]/)
        Rails.logger.warn("[CollavreSlack] Unmapped emoji: #{str.inspect} (#{str.bytes.map { |b| b.to_s(16) }.join(' ')})")
        # Return a safe default
        return "thumbsup"
      end

      result
    end
  end
end
