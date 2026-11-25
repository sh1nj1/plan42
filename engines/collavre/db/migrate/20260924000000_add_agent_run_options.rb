class AddAgentRunOptions < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :reasoning_effort, :string
    add_column :users, :codex_fast_mode, :boolean, default: false, null: false
    add_column :comments, :agent_run_options, :json
  end
end
