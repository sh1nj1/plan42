# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class AgentOrchestratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @ai_agent = users(:ai_bot)
        @creative = creatives(:tshirt)

        # Ensure AI agent has permission (searchable) for tests
        @ai_agent.update!(searchable: true)

        # Clear any existing routing expressions
        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
      end

      test "dispatches to mentioned AI agent" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => {
            "content" => "@#{@ai_agent.name}: hello",
            "mentioned_user" => { "id" => @ai_agent.id }
          },
          "comment" => { "content" => "@#{@ai_agent.name}: hello" }
        }

        # Verify the returned agents (jobs run inline in test)
        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent
      end

      test "does not dispatch when human is mentioned" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => {
            "content" => "@#{@user.name}: hello",
            "mentioned_user" => { "id" => @user.id }
          },
          "comment" => { "content" => "@#{@user.name}: hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_empty result
      end

      test "dispatches to agents matching routing expression" do
        @ai_agent.update!(routing_expression: 'event_name == "comment_created"')

        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_includes result, @ai_agent
      end

      test "does not dispatch when routing expression does not match" do
        @ai_agent.update!(routing_expression: 'event_name == "other_event"')

        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_not_includes result, @ai_agent
      end

      test "returns empty array when no agents match" do
        context = {
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "hello" },
          "comment" => { "content" => "hello" }
        }

        result = AgentOrchestrator.dispatch("comment_created", context)
        assert_empty result
      end
    end
  end
end
