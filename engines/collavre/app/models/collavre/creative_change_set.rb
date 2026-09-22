# frozen_string_literal: true

module Collavre
  class CreativeChangeSet < ApplicationRecord
    self.table_name = "creative_change_sets"

    ACTOR_KINDS = %w[human agent sync system].freeze
    ANCHOR_SOURCES = %w[agent_topic view_root import_target explicit none].freeze
    ORIGINS = %w[editor tool mcp import revert sync system].freeze
    STATUSES = %w[draft applied rejected reverted].freeze

    belongs_to :anchor_creative, class_name: "Collavre::Creative", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :task, class_name: "Collavre::Task", optional: true
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    belongs_to :reverts, class_name: "Collavre::CreativeChangeSet", optional: true
    belongs_to :reverted_by, class_name: "Collavre::CreativeChangeSet", optional: true

    has_many :creative_changes, class_name: "Collavre::CreativeChange",
                                foreign_key: :creative_change_set_id,
                                inverse_of: :change_set,
                                dependent: :destroy

    validates :actor_kind, inclusion: { in: ACTOR_KINDS }
    validates :anchor_source, inclusion: { in: ANCHOR_SOURCES }, allow_nil: true
    validates :origin, inclusion: { in: ORIGINS }
    validates :status, inclusion: { in: STATUSES }

    after_rollback :clear_current_reference, on: :create

    scope :visible_by_default, -> { where.not(origin: "sync") }
    scope :newest_first, -> { reorder(created_at: :desc, id: :desc) }

    def self.for_creative_scope(creative)
      changes = CreativeChange.arel_table
      condition = scope_condition(changes, creative.self_and_descendants)
      origin = creative.effective_origin
      condition = condition.or(scope_condition(changes, origin.self_and_descendants)) if origin != creative

      joins(:creative_changes).where(condition).distinct.newest_first
    end

    def self.scope_condition(changes, scope)
      ids = scope.select(:id).arel
      changes[:creative_id].in(ids).or(changes[:previous_parent_id].in(ids))
    end
    private_class_method :scope_condition

    def changes_for(mode)
      direction = mode == :revert ? :desc : :asc
      changes = creative_changes.order(position: direction).to_a
      mode == :draft ? changes : changes.reject(&:review_skipped?)
    end

    private

    def clear_current_reference
      Current.change_set = nil if Current.change_set.equal?(self)
    end
  end
end
