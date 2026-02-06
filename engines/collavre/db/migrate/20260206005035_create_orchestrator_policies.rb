# frozen_string_literal: true

class CreateOrchestratorPolicies < ActiveRecord::Migration[8.0]
  def change
    create_table :orchestrator_policies do |t|
      # Scope determines where this policy applies
      # - global: applies everywhere (scope_type/scope_id null)
      # - creative: applies to a specific creative
      # - topic: applies to a specific topic
      # - agent: applies to a specific agent
      t.string :scope_type, null: true
      t.bigint :scope_id, null: true

      # Policy type: matching, arbitration, scheduling
      t.string :policy_type, null: false

      # Configuration stored as JSON
      t.json :config, null: false, default: {}

      # Priority: lower number = higher priority (evaluated first)
      t.integer :priority, null: false, default: 100

      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :orchestrator_policies, [ :scope_type, :scope_id ]
    add_index :orchestrator_policies, [ :policy_type, :enabled ]
    add_index :orchestrator_policies, :priority
  end
end
