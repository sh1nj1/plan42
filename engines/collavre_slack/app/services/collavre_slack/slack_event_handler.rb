module CollavreSlack
  class SlackEventHandler
    def initialize(payload:)
      @payload = payload
    end

    def call
      return unless message_event?

      slack_account = SlackAccount.find_by(team_id: team_id)
      return unless slack_account

      channel_link = SlackChannelLink.find_by(
        slack_account: slack_account,
        channel_id: channel_id,
        is_active: true
      )
      return unless channel_link

      mapping = slack_account.slack_user_mappings.find_by(slack_user_id: event_user_id)
      user = mapping&.collavre_user || channel_link.created_by

      normalized_content = MentionMapping.from_slack(formatted_content, slack_account)

      {
        creative_id: channel_link.creative_id,
        user_id: user&.id,
        content: normalized_content,
        slack_channel_link_id: channel_link.id,
        slack_message_ts: event_ts
      }
    end

    private

    attr_reader :payload

    def message_event?
      event_type == "event_callback" && event_payload[:type] == "message" && event_payload[:subtype].blank?
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
  end
end
