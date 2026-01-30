module CollavreSlack
  class SlackCommentLink < ApplicationRecord
    self.table_name = "slack_comment_links"

    belongs_to :comment, class_name: "Collavre::Comment"
    belongs_to :slack_channel_link, class_name: "CollavreSlack::SlackChannelLink"

    validates :message_ts, presence: true
    validates :message_ts, uniqueness: { scope: :slack_channel_link_id }

    # Find by Slack channel and message timestamp
    def self.find_by_slack_message(slack_account:, channel_id:, message_ts:)
      joins(:slack_channel_link)
        .where(slack_channel_links: { slack_account_id: slack_account.id, channel_id: channel_id })
        .find_by(message_ts: message_ts)
    end
  end
end
