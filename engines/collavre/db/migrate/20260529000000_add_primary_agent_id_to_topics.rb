# frozen_string_literal: true

class AddPrimaryAgentIdToTopics < ActiveRecord::Migration[8.0]
  def up
    add_column :topics, :primary_agent_id, :integer
    add_index :topics, :primary_agent_id

    # Migrate existing data from orchestrator_policies using ActiveRecord (adapter-agnostic)
    Collavre::OrchestratorPolicy
      .where(policy_type: "arbitration", scope_type: "Topic", enabled: true)
      .find_each do |policy|
        agent_id = policy.config&.dig("primary_agent_id")
        next unless agent_id.present?

        Collavre::Topic.where(id: policy.scope_id).update_all(primary_agent_id: agent_id)
      end

    # Remove migrated topic-scoped arbitration policies
    Collavre::OrchestratorPolicy
      .where(scope_type: "Topic", policy_type: "arbitration")
      .delete_all
  end

  def down
    # Re-create orchestrator_policies from topics with primary_agent_id
    Collavre::Topic.where.not(primary_agent_id: nil).find_each do |topic|
      Collavre::OrchestratorPolicy.create!(
        policy_type: "arbitration",
        scope_type: "Topic",
        scope_id: topic.id,
        config: { "strategy" => "primary_first", "primary_agent_id" => topic.primary_agent_id },
        priority: 10,
        enabled: true
      )
    end

    remove_index :topics, :primary_agent_id
    remove_column :topics, :primary_agent_id
  end
end
