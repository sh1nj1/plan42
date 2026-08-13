# frozen_string_literal: true

require "test_helper"
require Rails.root.join(
  "engines/collavre/db/migrate/20260813000000_clear_claude_channel_presence_routing_expressions"
)

class ClearClaudeChannelPresenceRoutingExpressionsTest < ActiveSupport::TestCase
  setup do
    @migration = ClearClaudeChannelPresenceRoutingExpressions.new
  end

  test "clears only the legacy Claude Channel presence expression" do
    legacy_claude = create_agent(model: "claude-code", expression: "true")
    configured_claude = create_agent(
      model: "claude-code", expression: 'event_name == "comment_created"'
    )
    other_agent = create_agent(model: "gpt-4.1", expression: "true")

    @migration.up

    assert_nil legacy_claude.reload.routing_expression
    assert_equal 'event_name == "comment_created"', configured_claude.reload.routing_expression
    assert_equal "true", other_agent.reload.routing_expression
  end

  private

  def create_agent(model:, expression:)
    Collavre::User.create!(
      name: "migration-agent-#{SecureRandom.hex(4)}",
      email: "migration-agent-#{SecureRandom.hex(4)}@agent.test",
      password: "password123",
      llm_vendor: "anthropic",
      llm_model: model,
      routing_expression: expression
    )
  end
end
