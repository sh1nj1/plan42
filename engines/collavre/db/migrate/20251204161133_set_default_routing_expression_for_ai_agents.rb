class SetDefaultRoutingExpressionForAiAgents < ActiveRecord::Migration[8.1]
  # Migration-local model: the app's User declares enums and encrypted
  # attributes on columns that later migrations add, so loading it here breaks
  # migrating a fresh database.
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    # Find all AI agents (users with llm_vendor set) that have no routing expression
    MigrationUser.reset_column_information
    MigrationUser.where.not(llm_vendor: nil).where(routing_expression: [ nil, "" ])
                 .update_all(routing_expression: "chat.mentioned_user.id == agent.id")
  end

  def down
    # No-op or we could revert, but it's hard to know which ones were changed.
    # Generally data migrations like this don't need a strict down if they are just filling defaults.
  end
end
