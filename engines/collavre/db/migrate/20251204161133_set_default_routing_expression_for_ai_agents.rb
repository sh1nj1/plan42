class SetDefaultRoutingExpressionForAiAgents < ActiveRecord::Migration[8.1]
  def up
    # Find all AI agents (users with llm_vendor set) that have no routing expression
    User.where.not(llm_vendor: nil).where(routing_expression: [ nil, "" ]).find_each do |user|
      user.update_columns(routing_expression: "chat.mentioned_user.id == agent.id")
    end
  end

  def down
    # No-op or we could revert, but it's hard to know which ones were changed.
    # Generally data migrations like this don't need a strict down if they are just filling defaults.
  end
end
