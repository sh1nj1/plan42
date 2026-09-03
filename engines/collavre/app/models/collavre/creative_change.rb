# frozen_string_literal: true

module Collavre
  class CreativeChange < ApplicationRecord
    self.table_name = "creative_changes"

    OPERATIONS = %w[create update move reorder archive unarchive destroy].freeze

    belongs_to :change_set, class_name: "Collavre::CreativeChangeSet",
                            foreign_key: :creative_change_set_id,
                            inverse_of: :creative_changes
    belongs_to :creative, class_name: "Collavre::Creative"

    validates :operation, inclusion: { in: OPERATIONS }
    validates :creative_id, uniqueness: { scope: :creative_change_set_id }
  end
end
