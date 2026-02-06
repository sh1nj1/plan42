# frozen_string_literal: true

module Collavre
  # OrchestratorPolicy stores configuration for agent orchestration behavior.
  #
  # Table: orchestrator_policies
  #
  # Scope types:
  # - nil (global): Default policy applied everywhere
  # - "Creative": Policy for a specific creative/workspace
  # - "Topic": Policy for a specific topic/conversation
  # - "User": Policy for a specific agent
  #
  # Policy types:
  # - matching: How agents are matched to messages
  # - arbitration: How to select responders from candidates (floor control)
  # - scheduling: When/how to execute agent jobs (resource management)
  #
  # Example configs:
  #
  #   Arbitration policy (primary_first):
  #   {
  #     "strategy": "primary_first",
  #     "max_responders": 1,
  #     "primary_agent_id": 123
  #   }
  #
  #   Arbitration policy (round_robin):
  #   {
  #     "strategy": "round_robin",
  #     "max_responders": 1
  #   }
  #
  class OrchestratorPolicy < ApplicationRecord
    self.table_name = "orchestrator_policies"

    # Scope types
    SCOPE_TYPES = %w[Creative Topic User].freeze

    # Policy types
    POLICY_TYPES = %w[matching arbitration scheduling stuck_detection].freeze

    # Arbitration strategies
    ARBITRATION_STRATEGIES = %w[all primary_first round_robin bid].freeze

    # Validations
    validates :policy_type, presence: true, inclusion: { in: POLICY_TYPES }
    validates :scope_type, inclusion: { in: SCOPE_TYPES }, allow_nil: true
    validates :priority, presence: true, numericality: { only_integer: true }

    # Polymorphic scope
    belongs_to :scope, polymorphic: true, optional: true

    # Scopes
    scope :enabled, -> { where(enabled: true) }
    scope :by_priority, -> { order(priority: :asc) }
    scope :global, -> { where(scope_type: nil, scope_id: nil) }
    scope :for_type, ->(type) { where(policy_type: type) }

    # Class methods
    class << self
      # Find policies applicable to a given context
      # Returns policies in priority order (global < creative < topic < agent)
      def for_context(context, policy_type:)
        policies = enabled.for_type(policy_type).by_priority

        applicable = []

        # Global policies
        applicable.concat(policies.global.to_a)

        # Creative-level policies
        if context["creative"].present?
          creative_id = context["creative"]["id"]
          applicable.concat(
            policies.where(scope_type: "Creative", scope_id: creative_id).to_a
          )
        end

        # Topic-level policies
        if context["topic"].present?
          topic_id = context["topic"]["id"]
          applicable.concat(
            policies.where(scope_type: "Topic", scope_id: topic_id).to_a
          )
        end

        # Agent-level policies are handled separately per-agent

        # Note: We don't sort by priority globally here because scope hierarchy
        # (global < creative < topic) takes precedence. Each scope level is
        # already sorted by priority from the query.
        applicable
      end

      # Find policies for a specific agent
      def for_agent(agent_id, policy_type:)
        enabled
          .for_type(policy_type)
          .where(scope_type: "User", scope_id: agent_id)
          .by_priority
      end
    end

    # Instance methods

    # Get a config value with default
    def config_value(key, default: nil)
      config[key.to_s] || default
    end

    # Check if this is a global policy
    def global?
      scope_type.nil? && scope_id.nil?
    end

    # Get the arbitration strategy
    def arbitration_strategy
      return nil unless policy_type == "arbitration"

      config_value("strategy", default: "all")
    end
  end
end
