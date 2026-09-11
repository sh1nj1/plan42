class CreateAgentGatewaysAndWorkspaces < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_gateways do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :base_url, null: false
      t.text :admin_key, null: false
      t.text :completion_key, null: false
      t.text :identity_secret
      t.string :tenant_id, null: false, default: "collavre"
      t.integer :workspace_mode, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :agent_gateways, [ :owner_id, :name ], unique: true

    add_reference :users, :agent_gateway, foreign_key: true

    create_table :agent_workspaces do |t|
      t.references :agent, null: false, foreign_key: { to_table: :users }
      t.references :user, foreign_key: { to_table: :users }
      t.references :agent_gateway, null: false, foreign_key: true
      t.string :proxy_user_id, null: false
      t.string :manifest_token, null: false
      t.text :callback_token, null: false
      t.timestamps
    end

    add_index :agent_workspaces, :manifest_token, unique: true
    add_index :agent_workspaces, [ :agent_id, :agent_gateway_id ],
              unique: true, where: "user_id IS NULL", name: "idx_agent_workspaces_shared"
    add_index :agent_workspaces, [ :agent_id, :user_id, :agent_gateway_id ],
              unique: true, where: "user_id IS NOT NULL", name: "idx_agent_workspaces_per_user"
  end
end
