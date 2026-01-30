module CollavreSlack
  class SlackMessageLog < ApplicationRecord
    self.table_name = "slack_message_logs"

    belongs_to :slack_channel_link, class_name: "CollavreSlack::SlackChannelLink"
    belongs_to :sender, class_name: "::User", optional: true
    belongs_to :comment, class_name: "Collavre::Comment", optional: true

    validates :status, :message, presence: true
  end
end
