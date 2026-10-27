# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class PromptBudgetTest < ActiveSupport::TestCase
      setup do
        @agent = users(:ai_bot)
      end

      def entry(kind, text, **extra)
        { role: "user", kind: kind, parts: [ { text: text } ] }.merge(extra)
      end

      def limit!(chars)
        @agent.update!(agent_conf: { "context" => { "max_prompt_chars" => chars } }.to_json)
      end

      def total(messages)
        messages.sum { |m| m[:parts].sum { |p| p[:text].to_s.length } }
      end

      test "leaves a prompt under the default cap alone" do
        messages = [ entry(:creative_context, "a" * 1_000), entry(:trigger, "hi") ]

        assert_equal messages.deep_dup, PromptBudget.enforce!(messages, @agent)
      end

      test "sheds the oldest history first, then later linked and context creatives" do
        limit!(80)
        messages = [
          entry(:creative_context, "Creative Path: Root (id: 1)\n# Root"),
          entry(:context_creative, "c1" * 10), entry(:context_creative, "c2" * 10),
          entry(:referenced_creative, "r" * 20),
          entry(:chat_history, "h" * 20, comment_id: 1), entry(:chat_history, "h" * 20, comment_id: 2),
          entry(:trigger, "now")
        ]

        result = PromptBudget.enforce!(messages, @agent)

        assert_equal [ :creative_context, :context_creative, :context_creative, :trigger ], result.map { |m| m[:kind] }
        assert_operator total(result), :<=, 80

        limit!(60)
        result = PromptBudget.enforce!(result, @agent)
        assert_equal [ "c1" * 10 ], result.select { |m| m[:kind] == :context_creative }.map { |m| m.dig(:parts, 0, :text) }
      end

      test "removes identical history entries one at a time" do
        limit!(25)
        messages = [ entry(:chat_history, "same" * 5), entry(:chat_history, "same" * 5), entry(:trigger, "now") ]

        assert_equal 2, PromptBudget.enforce!(messages, @agent).size
      end

      test "reduces the current creative to its path when context alone is over the cap" do
        limit!(60)
        messages = [
          entry(:creative_context, "Creative Path: Root (id: 1)\nTopic: Main (id: 2)\n# Root\n#{'x' * 500}"),
          entry(:trigger, "now")
        ]

        result = PromptBudget.enforce!(messages, @agent)

        assert_equal "Creative Path: Root (id: 1)\nTopic: Main (id: 2)", result.first.dig(:parts, 0, :text)
      end

      test "cuts the largest trigger text part as a last resort and keeps images" do
        limit!(100)
        trigger = { role: "user", kind: :trigger, parts: [ { text: "Task id" }, { text: "t" * 500 }, { image: :blob } ] }

        result = PromptBudget.enforce!([ trigger ], @agent)

        parts = result.first[:parts]
        assert_equal "Task id", parts.first[:text]
        assert_includes parts[1][:text], "Message truncated to fit the context budget"
        assert_equal :blob, parts.last[:image]
        assert_equal 100, total(result)
      end

      test "does nothing more when there is no creative context or trigger to cut" do
        limit!(5)
        messages = [ entry(:chat_history, "h" * 20) ]

        assert_empty PromptBudget.enforce!(messages, @agent)
      end
    end
  end
end
