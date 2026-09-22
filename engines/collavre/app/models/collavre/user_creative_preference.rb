module Collavre
  class UserCreativePreference < ApplicationRecord
    self.table_name = "user_creative_preferences"

    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :last_topic, class_name: "Collavre::Topic", optional: true

    def expanded_ids_root_first
      ids = (expanded_status || {}).select { |_, expanded| expanded }.keys
      Creatives::WorkspaceExpansionOrder.new(user: user, expanded_ids: ids).call
    end

    def set_expanded(node_id, expanded)
      state = expanded_status || {}
      expanded ? state[node_id] = true : state.delete(node_id)
      self.expanded_status = state
    end

    # Both operations run under the preference lock, across all tabs/documents.
    def issue_expansion_save_fence
      order = Creatives::ExpansionSaveOrder.new(expansion_save_sequences)
      fence = order.issue
      self.expansion_save_sequences = order.state
      fence
    end

    def accept_expansion_save?(fence, node_id)
      order = Creatives::ExpansionSaveOrder.new(expansion_save_sequences)
      accepted = order.accept?(fence, node_id)
      self.expansion_save_sequences = order.state if accepted
      accepted
    end

    validates :expanded_status, presence: true, unless: -> {
      last_topic_id? || last_topic_all_messages? || last_topic_revision.to_i.positive? ||
        last_topic_save_fence_issued.to_i.positive? || expansion_save_sequences.present?
    }
    validates :creative_id, uniqueness: { scope: :user_id }, allow_nil: true
  end
end
