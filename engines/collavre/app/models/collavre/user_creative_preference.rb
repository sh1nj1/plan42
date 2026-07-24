module Collavre
  class UserCreativePreference < ApplicationRecord
    self.table_name = "user_creative_preferences"

    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :last_topic, class_name: "Collavre::Topic", optional: true

    validates :expanded_status, presence: true, unless: :last_topic_id?
    validates :creative_id, uniqueness: { scope: :user_id }, allow_nil: true
  end
end
