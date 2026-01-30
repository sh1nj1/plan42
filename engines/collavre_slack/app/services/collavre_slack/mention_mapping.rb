module CollavreSlack
  module MentionMapping
    SLACK_MENTION_REGEX = /<@([A-Z0-9]+)>/.freeze
    COLLABRE_MENTION_REGEX = /@([^:]+):/.freeze

    def self.from_slack(text, slack_account)
      return text if text.blank?

      text.gsub(SLACK_MENTION_REGEX) do |match|
        slack_user_id = Regexp.last_match(1)
        mapping = slack_account.slack_user_mappings.includes(:collavre_user).find_by(slack_user_id: slack_user_id)

        if mapping
          "@#{mapping.collavre_user.name}:"
        else
          # Fetch display name from Slack API for unmapped users
          display_name = fetch_slack_display_name(slack_account, slack_user_id)
          display_name ? "@#{display_name}:" : match
        end
      end
    end

    def self.fetch_slack_display_name(slack_account, slack_user_id)
      client = SlackClient.new(access_token: slack_account.access_token)
      client.get_user_display_name(user_id: slack_user_id)
    rescue StandardError => e
      Rails.logger.warn("[CollavreSlack] Failed to fetch Slack user info: #{e.message}")
      nil
    end

    def self.to_slack(text, slack_account)
      return text if text.blank?

      mappings = slack_account.slack_user_mappings.includes(:collavre_user).to_a
      by_name = mappings.index_by { |mapping| mapping.collavre_user.name.to_s.downcase }
      by_email = mappings.index_by { |mapping| mapping.collavre_user.email.to_s.downcase }

      text.gsub(COLLABRE_MENTION_REGEX) do |match|
        key = Regexp.last_match(1).to_s.downcase
        mapping = by_name[key] || by_email[key]
        mapping ? "<@#{mapping.slack_user_id}>" : match
      end
    end
  end
end
