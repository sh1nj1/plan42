module CollavreSlack
  module MentionMapping
    SLACK_MENTION_REGEX = /<@([A-Z0-9]+)>/.freeze
    COLLABRE_MENTION_REGEX = /@([^:]+):/.freeze

    def self.from_slack(text, slack_account)
      return text if text.blank?

      text.gsub(SLACK_MENTION_REGEX) do |match|
        slack_user_id = Regexp.last_match(1)
        mapping = slack_account.slack_user_mappings.includes(:collavre_user).find_by(slack_user_id: slack_user_id)
        mapping ? "@#{mapping.collavre_user.name}:" : match
      end
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
