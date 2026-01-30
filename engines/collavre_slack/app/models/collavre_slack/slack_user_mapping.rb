module CollavreSlack
  class SlackUserMapping < ApplicationRecord
    self.table_name = "slack_user_mappings"

    belongs_to :slack_account, class_name: "CollavreSlack::SlackAccount"
    belongs_to :collavre_user, class_name: Collavre.configuration.user_class_name

    validates :slack_user_id, presence: true, uniqueness: { scope: :slack_account_id }
  end
end
