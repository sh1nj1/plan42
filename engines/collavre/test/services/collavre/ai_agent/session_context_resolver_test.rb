# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class SessionContextResolverTest < ActiveSupport::TestCase
      setup do
        @system_prompt = "You are a helpful assistant"
        @full_messages = [
          { role: "user", kind: :creative_context, parts: [ { text: "Creative (id: 1):\n# Hello" } ] },
          { role: "user", kind: :context_creative, parts: [ { text: "Context Creative (id: 2):\n# Config" } ] },
          { role: "user", kind: :chat_history, parts: [ { text: "[Alice]: hi" } ] },
          { role: "model", kind: :chat_history, parts: [ { text: "Hello!" } ] },
          { role: "user", kind: :trigger, parts: [ { text: "[Alice]: Follow-up" } ] }
        ]
      end

      test "returns full payload when agent does not support sessions" do
        agent = build_agent(supports_session: false)
        messages_data = { messages: @full_messages, first_message: false, context_changed: false }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        assert_equal @full_messages, result[:messages]
        assert_equal @system_prompt, result[:system_prompt]
        assert_equal false, result[:first_message]
        assert_equal false, result[:context_changed]
      end

      test "returns full payload on first message even when session supported" do
        agent = build_agent(supports_session: true)
        messages_data = { messages: @full_messages, first_message: true, context_changed: false }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        assert_no_chat_history(result[:messages])
        assert_equal @system_prompt, result[:system_prompt]
        assert_equal true, result[:first_message]
      end

      test "returns full payload when context changed even when session supported" do
        agent = build_agent(supports_session: true)
        messages_data = { messages: @full_messages, first_message: false, context_changed: true }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        assert_no_chat_history(result[:messages])
        assert_equal @system_prompt, result[:system_prompt]
        assert_equal true, result[:context_changed]
      end

      test "full payload for session agent excludes chat_history but keeps context and trigger" do
        agent = build_agent(supports_session: true)
        messages_data = { messages: @full_messages, first_message: true, context_changed: false }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        kinds = result[:messages].map { |m| m[:kind] }
        assert_includes kinds, :creative_context
        assert_includes kinds, :context_creative
        assert_includes kinds, :trigger
        assert_not_includes kinds, :chat_history
      end

      test "full payload for non-session agent includes chat_history" do
        agent = build_agent(supports_session: false)
        messages_data = { messages: @full_messages, first_message: true, context_changed: false }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        kinds = result[:messages].map { |m| m[:kind] }
        assert_includes kinds, :chat_history
      end

      test "returns incremental payload for warm session" do
        agent = build_agent(supports_session: true)
        messages_data = { messages: @full_messages, first_message: false, context_changed: false }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        assert_equal 1, result[:messages].length
        assert_equal :trigger, result[:messages].first[:kind]
        assert_equal "[Alice]: Follow-up", result[:messages].first[:parts].first[:text]
        assert_nil result[:system_prompt]
        assert_equal false, result[:first_message]
        assert_equal false, result[:context_changed]
      end

      test "incremental payload preserves multiple trigger messages" do
        agent = build_agent(supports_session: true)
        messages_with_two_triggers = @full_messages + [
          { role: "user", kind: :trigger, parts: [ { text: "Another trigger" } ] }
        ]
        messages_data = { messages: messages_with_two_triggers, first_message: false, context_changed: false }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        assert_equal 2, result[:messages].length
        assert(result[:messages].all? { |m| m[:kind] == :trigger })
      end

      test "returns full payload when both first_message and context_changed" do
        agent = build_agent(supports_session: true)
        messages_data = { messages: @full_messages, first_message: true, context_changed: true }

        result = SessionContextResolver.new(
          agent: agent, messages_data: messages_data, system_prompt: @system_prompt
        ).resolve

        assert_no_chat_history(result[:messages])
        assert_equal @system_prompt, result[:system_prompt]
      end

      private

      def build_agent(supports_session:)
        agent = Object.new
        val = supports_session
        agent.define_singleton_method(:supports_session?) { val }
        agent
      end

      def assert_no_chat_history(messages)
        chat_history = messages.select { |m| m[:kind] == :chat_history }
        assert_empty chat_history, "Expected no chat_history messages but found #{chat_history.length}"
      end
    end
  end
end
