module CollavreSlack
  class SlackMessageLog < ApplicationRecord
    self.table_name = "slack_message_logs"

    belongs_to :slack_channel_link, class_name: "CollavreSlack::SlackChannelLink"
    belongs_to :sender, class_name: Collavre.configuration.user_class_name, optional: true

    validates :status, :message, presence: true
  end
end
