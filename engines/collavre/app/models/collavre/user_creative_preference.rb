module Collavre
  class UserCreativePreference < ApplicationRecord
    self.table_name = "user_creative_preferences"

    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :last_topic, class_name: "Collavre::Topic", optional: true

    # Persisted hash insertion order need not match the tree (a child may have
    # been toggled before its parent). Keep ancestors when the client caps IDs.
    def expanded_ids_root_first
      ids = (expanded_status || {}).select { |_, expanded| expanded }.keys
      depths = CreativeHierarchy.where(descendant_id: ids).group(:descendant_id).maximum(:generations)
      ids.select { |id| depths.key?(id.to_i) }.sort_by { |id| depths.fetch(id.to_i) }
    end

    validates :expanded_status, presence: true, unless: -> {
      last_topic_id? || last_topic_all_messages? || last_topic_revision.to_i.positive? ||
        last_topic_save_fence_issued.to_i.positive?
    }
    validates :creative_id, uniqueness: { scope: :user_id }, allow_nil: true
  end
end
