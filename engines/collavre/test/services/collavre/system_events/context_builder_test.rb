require "test_helper"

module Collavre
  module SystemEvents
    class ContextBuilderTest < ActiveSupport::TestCase
      setup do
        @human_user = Collavre::User.create!(
          name: "John",
          email: "john-#{SecureRandom.hex(4)}@test.test",
          password: "password123"
        )

        @ai_agent = Collavre::User.create!(
          name: "dev-agent",
          email: "dev-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are a developer agent."
        )

        @creative = Collavre::Creative.create!(
          description: "Test project",
          user: @human_user
        )
      end

      test "builds sender context for human user" do
        context = {
          comment: { id: 1, content: "Hello", user_id: @human_user.id },
          creative: { id: @creative.id }
        }

        result = ContextBuilder.new(context).build

        assert result["sender"].present?
        assert_equal @human_user.id, result["sender"]["id"]
        assert_equal @human_user.name, result["sender"]["name"]
        assert_equal false, result["sender"]["is_ai"]
        assert_equal "human", result["sender"]["type"]
      end

      test "builds sender context for AI agent" do
        context = {
          comment: { id: 1, content: "Hello", user_id: @ai_agent.id },
          creative: { id: @creative.id }
        }

        result = ContextBuilder.new(context).build

        assert result["sender"].present?
        assert_equal @ai_agent.id, result["sender"]["id"]
        assert_equal @ai_agent.name, result["sender"]["name"]
        assert_equal true, result["sender"]["is_ai"]
        assert_equal "developer", result["sender"]["type"]
      end

      test "extracts agent type from system prompt" do
        qa_agent = Collavre::User.create!(
          name: "qa-agent",
          email: "qa-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          system_prompt: "You are a QA tester."
        )

        context = {
          comment: { id: 1, content: "Review this", user_id: qa_agent.id }
        }

        result = ContextBuilder.new(context).build

        assert_equal "qa", result["sender"]["type"]
      end

      test "returns nil sender when user_id is missing" do
        context = {
          comment: { id: 1, content: "Hello" }
        }

        result = ContextBuilder.new(context).build

        assert_nil result["sender"]
      end

      test "returns nil sender when user not found" do
        context = {
          comment: { id: 1, content: "Hello", user_id: 999999 }
        }

        result = ContextBuilder.new(context).build

        assert_nil result["sender"]
      end

      test "builds mentioned_user from chat content" do
        context = {
          chat: { content: "@#{@ai_agent.name}: please help" }
        }

        result = ContextBuilder.new(context).build

        assert result["chat"]["mentioned_user"].present?
        assert_equal @ai_agent.id, result["chat"]["mentioned_user"]["id"]
      end

      test "handles missing chat context gracefully" do
        context = {
          comment: { id: 1, content: "Hello" }
        }

        result = ContextBuilder.new(context).build

        assert_nil result["chat"]
      end

      test "preserves existing context keys" do
        context = {
          comment: { id: 1, content: "Hello", user_id: @human_user.id },
          creative: { id: @creative.id, description: "Test" },
          custom_key: "custom_value"
        }

        result = ContextBuilder.new(context).build

        assert_equal "custom_value", result["custom_key"]
        assert_equal @creative.id, result["creative"]["id"]
      end
    end
  end
end
