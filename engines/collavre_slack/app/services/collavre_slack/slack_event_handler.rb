module CollavreSlack
  class SlackEventHandler
    def initialize(payload:)
      @payload = payload
    end

    def call
      return handle_reaction_event if reaction_event?
      return unless message_event?

      slack_account = SlackAccount.find_by(team_id: team_id)
      return unless slack_account

      channel_link = SlackChannelLink.find_by(
        slack_account: slack_account,
        channel_id: channel_id,
        is_active: true
      )
      return unless channel_link

      user_result = find_or_map_user(slack_account, event_user_id)
      user = user_result[:user] || channel_link.created_by
      slack_display_name = user_result[:slack_display_name]

      normalized_content = MentionMapping.from_slack(formatted_content, slack_account)

      # Prepend Slack username if user is not mapped
      if user_result[:user].nil? && slack_display_name.present?
        normalized_content = "[Slack: @#{slack_display_name}] #{normalized_content}"
      end

      {
        type: :message,
        creative_id: channel_link.creative_id,
        user_id: user&.id,
        content: normalized_content,
        slack_channel_link_id: channel_link.id,
        slack_message_ts: event_ts
      }
    end

    def handle_reaction_event
      slack_account = SlackAccount.find_by(team_id: team_id)
      return unless slack_account

      # Reaction events have item.channel and item.ts
      item = event_payload[:item] || {}
      reaction_channel_id = item[:channel]
      reaction_message_ts = item[:ts]

      return unless reaction_channel_id && reaction_message_ts

      # Find the comment link by Slack message
      comment_link = SlackCommentLink.find_by_slack_message(
        slack_account: slack_account,
        channel_id: reaction_channel_id,
        message_ts: reaction_message_ts
      )
      return unless comment_link

      # Map Slack user to Collavre user
      user_result = find_or_map_user(slack_account, event_user_id)
      user = user_result[:user]
      return unless user # Can't add reaction without a mapped user

      {
        type: reaction_action,
        comment_id: comment_link.comment_id,
        user_id: user.id,
        emoji: normalize_emoji_from_slack(event_payload[:reaction])
      }
    end

    private

    attr_reader :payload

    def message_event?
      return false unless event_type == "event_callback"
      return false unless event_payload[:type] == "message"
      return false if event_payload[:subtype].present?
      # Skip bot messages to prevent loops
      return false if event_payload[:bot_id].present?
      true
    end

    def reaction_event?
      return false unless event_type == "event_callback"
      %w[reaction_added reaction_removed].include?(event_payload[:type])
    end

    def reaction_action
      event_payload[:type] == "reaction_added" ? :reaction_added : :reaction_removed
    end

    def normalize_emoji_from_slack(slack_emoji)
      # Slack uses names like "thumbsup", convert to standard emoji or keep as-is
      # Common Slack emoji names to Unicode mappings
      slack_to_emoji = {
        "thumbsup" => "\u{1F44D}",
        "+1" => "\u{1F44D}",
        "thumbsdown" => "\u{1F44E}",
        "-1" => "\u{1F44E}",
        "heart" => "\u{2764}",
        "grinning" => "\u{1F600}",
        "joy" => "\u{1F602}",
        "clap" => "\u{1F44F}",
        "tada" => "\u{1F389}",
        "eyes" => "\u{1F440}",
        "pray" => "\u{1F64F}",
        "fire" => "\u{1F525}",
        "white_check_mark" => "\u{2705}",
        "x" => "\u{274C}",
        "rocket" => "\u{1F680}"
      }

      # Return mapped emoji or the original name prefixed with colon
      slack_to_emoji[slack_emoji.to_s] || ":#{slack_emoji}:"
    end

    def team_id
      payload[:team_id] || payload[:team]
    end

    def event_payload
      payload[:event] || {}
    end

    def event_text
      event_payload[:text].to_s
    end

    def formatted_content
      content = event_text
      content = "[Thread reply]\n#{content}" if thread_reply?
      attachment_lines = attachment_summaries
      if attachment_lines.any?
        content = [content, "", "Attachments:", *attachment_lines].join("\n")
      end
      content
    end

    def attachment_summaries
      files = Array(event_payload[:files])
      files.filter_map do |file|
        next unless file.is_a?(Hash)
        name = file[:name] || file[:title] || "file"
        url = file[:url_private] || file[:url_private_download]
        url ? "- #{name}: #{url}" : "- #{name}"
      end
    end

    def thread_reply?
      event_payload[:thread_ts].present? && event_payload[:thread_ts] != event_payload[:ts]
    end

    def event_user_id
      event_payload[:user]
    end

    def event_ts
      event_payload[:ts]
    end

    def channel_id
      event_payload[:channel]
    end

    def event_type
      payload[:type]
    end

    def find_or_map_user(slack_account, slack_user_id)
      # First check existing mapping
      mapping = slack_account.slack_user_mappings.find_by(slack_user_id: slack_user_id)
      return { user: mapping.collavre_user, slack_display_name: nil } if mapping

      # Try to find by email
      client = SlackClient.new(access_token: slack_account.access_token)
      response = client.get_user_info(user_id: slack_user_id)
      return { user: nil, slack_display_name: nil } unless response[:ok]

      profile = response.dig(:user, :profile) || {}
      slack_display_name = profile[:display_name].presence || profile[:real_name].presence || response.dig(:user, :name)
      email = profile[:email]

      # Try to find Collavre user by email
      if email.present?
        collavre_user = ::User.find_by(email: email)
        if collavre_user
          # Auto-create mapping for future use
          slack_account.slack_user_mappings.create(
            slack_user_id: slack_user_id,
            collavre_user: collavre_user
          )
          Rails.logger.info("[CollavreSlack] Auto-mapped Slack user #{slack_user_id} to Collavre user #{collavre_user.id} by email")
          return { user: collavre_user, slack_display_name: nil }
        end
      end

      # No mapping found - return slack display name for attribution
      { user: nil, slack_display_name: slack_display_name }
    rescue StandardError => e
      Rails.logger.warn("[CollavreSlack] Failed to map user: #{e.message}")
      { user: nil, slack_display_name: nil }
    end
  end
end
