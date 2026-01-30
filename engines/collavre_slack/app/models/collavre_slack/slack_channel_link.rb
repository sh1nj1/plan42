module CollavreSlack
  class SlackChannelLink < ApplicationRecord
    self.table_name = "slack_channel_links"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :slack_account, class_name: "CollavreSlack::SlackAccount"
    belongs_to :created_by, class_name: "::User"

    has_many :slack_message_logs, class_name: "CollavreSlack::SlackMessageLog", dependent: :destroy
    has_many :slack_comment_links, class_name: "CollavreSlack::SlackCommentLink", dependent: :destroy

    validates :channel_id, :channel_name, presence: true
    # 1:1 relationship: one creative can only be linked to one Slack channel
    validates :creative_id, uniqueness: { message: I18n.t("collavre_slack.errors.creative_already_linked", default: "is already linked to a Slack channel") }
  end
end
