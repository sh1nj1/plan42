module Collavre
  class Topic < ApplicationRecord
    self.table_name = "topics"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name

    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy
    has_many :user_creative_preferences_as_last_topic, class_name: "Collavre::UserCreativePreference",
             foreign_key: :last_topic_id, dependent: :nullify, inverse_of: :last_topic

    # --- Archive scopes ---
    scope :active, -> { where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }

    validates :name, presence: true, uniqueness: { scope: :creative_id }

    before_create :set_default_position

    default_scope { order(:position) }

    # Returns the primary agent User for this topic (from orchestration policy)
    def primary_agent
      policy = OrchestratorPolicy.find_by(
        policy_type: "arbitration",
        scope_type: "Topic",
        scope_id: id
      )
      return nil unless policy&.config&.dig("primary_agent_id")

      User.find_by(id: policy.config["primary_agent_id"])
    end

    # Sets or replaces the primary agent for this topic
    def set_primary_agent!(agent)
      policy = OrchestratorPolicy.find_or_initialize_by(
        policy_type: "arbitration",
        scope_type: "Topic",
        scope_id: id
      )
      policy.update!(
        config: {
          "strategy" => "primary_first",
          "primary_agent_id" => agent.id
        },
        priority: 10,
        enabled: true
      )
    end

    def archived?
      archived_at.present?
    end

    def archive!
      update!(archived_at: Time.current)
    end

    def unarchive!
      update!(archived_at: nil)
    end

    private

    def set_default_position
      return if position_changed? && position != 0

      self.position = (Topic.unscoped.where(creative_id: creative_id).maximum(:position) || -1) + 1
    end
  end
end
