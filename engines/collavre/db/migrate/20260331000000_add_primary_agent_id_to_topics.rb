# frozen_string_literal: true

class AddPrimaryAgentIdToTopics < ActiveRecord::Migration[8.0]
  def up
    add_column :topics, :primary_agent_id, :integer
    add_index :topics, :primary_agent_id

    # Migrate existing data from orchestrator_policies
    execute <<~SQL
      UPDATE topics
      SET primary_agent_id = CAST(
        json_extract(orchestrator_policies.config, '$.primary_agent_id') AS INTEGER
      )
      FROM orchestrator_policies
      WHERE orchestrator_policies.scope_type = 'Topic'
        AND orchestrator_policies.scope_id = topics.id
        AND orchestrator_policies.policy_type = 'arbitration'
        AND orchestrator_policies.enabled = 1
        AND json_extract(orchestrator_policies.config, '$.primary_agent_id') IS NOT NULL
    SQL

    # Remove migrated topic-scoped arbitration policies
    execute <<~SQL
      DELETE FROM orchestrator_policies
      WHERE scope_type = 'Topic'
        AND policy_type = 'arbitration'
    SQL
  end

  def down
    # Re-create orchestrator_policies from topics with primary_agent_id
    execute <<~SQL
      INSERT INTO orchestrator_policies (policy_type, scope_type, scope_id, config, priority, enabled, created_at, updated_at)
      SELECT
        'arbitration',
        'Topic',
        id,
        json_object('strategy', 'primary_first', 'primary_agent_id', primary_agent_id),
        10,
        1,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM topics
      WHERE primary_agent_id IS NOT NULL
    SQL

    remove_index :topics, :primary_agent_id
    remove_column :topics, :primary_agent_id
  end
end
