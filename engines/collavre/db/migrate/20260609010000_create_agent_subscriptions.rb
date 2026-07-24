# frozen_string_literal: true

# Presence rows for Claude Channel session subscriptions. One shared agent can
# now have many concurrent live sessions; routing_expression must stay active
# while ANY of them is subscribed. A single routing_subscription_token column
# (last-write-wins) cannot represent N subscribers — one session's unsubscribe
# would clear routing for a still-live sibling. Each live subscription gets a
# row here; routing turns off only when the last row is removed.
class CreateAgentSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_subscriptions do |t|
      t.integer :agent_id, null: false
      t.string :token, null: false
      t.timestamps
    end
    add_index :agent_subscriptions, :agent_id
    add_index :agent_subscriptions, :token, unique: true
  end
end
