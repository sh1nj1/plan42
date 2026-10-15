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

    # Precedence of the context scopes; later levels override earlier ones.
    CONTEXT_SCOPE_RANK = { nil => 0, "Creative" => 1, "Topic" => 2 }.freeze

    # Policy types
    POLICY_TYPES = %w[matching arbitration scheduling stuck_detection collaboration].freeze

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
        for_context_by_type(context).fetch(policy_type, [])
      end

      # Every enabled context policy, grouped by policy type, in one query.
      #
      # A dispatch asks for several policy types (matching, arbitration,
      # scheduling); one query per type and scope level repeated the same
      # lookup up to nine times. Within each group the scope hierarchy
      # (global < creative < topic) takes precedence, then priority, then id
      # so that equal priorities resolve the same way on every database.
      #
      # Agent-level policies are handled separately per-agent.
      def for_context_by_type(context)
        scopes = [ global ]
        scopes << where(scope_type: "Creative", scope_id: context["creative"]["id"]) if context["creative"].present?
        scopes << where(scope_type: "Topic", scope_id: context["topic"]["id"]) if context["topic"].present?

        rows = enabled.and(scopes.reduce(:or)).order(:priority, :id).to_a
        rows.each_with_index
          .sort_by { |policy, index| [ CONTEXT_SCOPE_RANK.fetch(policy.scope_type), index ] }
          .map(&:first)
          .group_by(&:policy_type)
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
