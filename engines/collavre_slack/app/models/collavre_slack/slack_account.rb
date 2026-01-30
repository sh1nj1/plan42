module CollavreSlack
  class SlackAccount < ApplicationRecord
    self.table_name = "slack_accounts"

    belongs_to :user, class_name: "::User"
    has_many :slack_channel_links, class_name: "CollavreSlack::SlackChannelLink", dependent: :destroy
    has_many :slack_user_mappings, class_name: "CollavreSlack::SlackUserMapping", dependent: :destroy

    validates :team_id, :team_name, :access_token, presence: true

    encrypts :access_token, deterministic: false
  end
end
