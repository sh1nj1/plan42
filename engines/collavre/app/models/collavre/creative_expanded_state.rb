module Collavre
  class CreativeExpandedState < ApplicationRecord
    self.table_name = "creative_expanded_states"

    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name

    validates :expanded_status, presence: true
    validates :creative_id, uniqueness: { scope: :user_id }, allow_nil: true
  end
end
