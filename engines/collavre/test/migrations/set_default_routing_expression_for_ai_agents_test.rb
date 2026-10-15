# frozen_string_literal: true

require "test_helper"
require Rails.root.join(
  "engines/collavre/db/migrate/20251204161133_set_default_routing_expression_for_ai_agents"
)

class SetDefaultRoutingExpressionForAiAgentsTest < ActiveSupport::TestCase
  DEFAULT_EXPRESSION = "chat.mentioned_user.id == agent.id"

  setup do
    @migration = SetDefaultRoutingExpressionForAiAgents.new
  end

  test "fills a default routing expression only for agents without one" do
    blank_agent = create_user(vendor: "anthropic", expression: "")
    nil_agent = create_user(vendor: "anthropic", expression: nil)
    configured_agent = create_user(vendor: "anthropic", expression: "true")
    human = create_user(vendor: nil, expression: nil)

    @migration.up

    assert_equal DEFAULT_EXPRESSION, blank_agent.reload.routing_expression
    assert_equal DEFAULT_EXPRESSION, nil_agent.reload.routing_expression
    assert_equal "true", configured_agent.reload.routing_expression
    assert_nil human.reload.routing_expression
  end

  test "uses a migration-local model instead of the app's User" do
    assert_equal "users", SetDefaultRoutingExpressionForAiAgents::MigrationUser.table_name
    assert_empty SetDefaultRoutingExpressionForAiAgents::MigrationUser.defined_enums
  end

  test "rollback is a no-op" do
    agent = create_user(vendor: "anthropic", expression: DEFAULT_EXPRESSION)

    assert_nil @migration.down
    assert_equal DEFAULT_EXPRESSION, agent.reload.routing_expression
  end

  private

  def create_user(vendor:, expression:)
    user = Collavre::User.create!(
      name: "migration-user-#{SecureRandom.hex(4)}",
      email: "migration-user-#{SecureRandom.hex(4)}@example.test",
      password: "password123",
      llm_vendor: vendor
    )
    user.update_columns(routing_expression: expression)
    user
  end
end
