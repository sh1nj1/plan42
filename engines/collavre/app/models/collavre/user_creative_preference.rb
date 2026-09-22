module Collavre
  class UserCreativePreference < ApplicationRecord
    self.table_name = "user_creative_preferences"

    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :last_topic, class_name: "Collavre::Topic", optional: true

    def self.root_expanded_ids_for(user)
      # Legacy writers can create new duplicates after deployment cleanup.
      # Match consolidation's ID-ordered merge without mutating rows on reads.
      state = where(user: user, creative_id: nil).order(:id).pluck(:expanded_status)
        .each_with_object({}) { |status, merged| merged.merge!(status) }
      new(user: user, expanded_status: state).expanded_ids_root_first
    end

    def expanded_ids_root_first
      ids = (expanded_status || {}).select { |_, expanded| expanded }.keys
      Creatives::WorkspaceExpansionOrder.new(user: user, expanded_ids: ids).call
    end

    def set_expanded(node_id, expanded)
      state = expanded_status || {}
      expanded ? state[node_id] = true : state.delete(node_id)
      self.expanded_status = state
    end

    validates :expanded_status, presence: true, unless: -> {
      last_topic_id? || last_topic_all_messages? || last_topic_revision.to_i.positive? ||
        last_topic_save_fence_issued.to_i.positive?
    }
    validates :creative_id, uniqueness: { scope: :user_id }, allow_nil: true
  end
end
