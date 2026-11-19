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

      test "bounds a long breadcrumb while retaining the current request" do
        limit!(500)
        messages = [ entry(:creative_context, "Creative Path: #{'x' * 600}"), entry(:trigger, "cancel the earlier request") ]

        result = PromptBudget.enforce!(messages, @agent)

        assert_equal "cancel the earlier request", result.last.dig(:parts, 0, :text)
        assert_equal 500, total(result)
      end

      test "preserves the anchor instead of an oversized merged prefix" do
        limit!(100)
        trigger = entry(:trigger, "old request " * 100 + "cancel the earlier request")
        trigger[:parts].first[:anchor_offset] = 1200
        trigger[:parts].unshift(text: "Task id")

        result = PromptBudget.enforce!([ trigger ], @agent)

        assert_equal "cancel the earlier request", result.first.dig(:parts, 1, :text)
        assert_equal "Task id", result.first.dig(:parts, 0, :text)
        assert_equal 0, result.first[:parts][1][:anchor_offset]
      end

      test "bounds multiple trigger text parts and a note larger than the cap" do
        limit!(5)
        trigger = entry(:trigger, "a" * 100)
        trigger[:parts] << { text: "b" * 100 }
        trigger[:parts] << { image: :blob }

        result = PromptBudget.enforce!([ trigger ], @agent)

        assert_equal 5, total(result)
        assert_equal :blob, result.first[:parts].last[:image]
      end

      test "bounds multipart retained context without changing images" do
        limit!(10)
        context = entry(:creative_context, "Creative Path: Root")
        context[:parts] += [ { image: :blob }, { text: "extra" * 100 } ]

        result = PromptBudget.enforce!([ context, entry(:trigger, "now") ], @agent)

        assert_equal 10, total(result)
        assert_equal :blob, result.first[:parts][1][:image]
        assert_equal "now", result.last.dig(:parts, 0, :text)
      end

      test "negative limits become zero" do
        limit!(-1)
        messages = [ entry(:creative_context, "Creative Path: Root"), entry(:trigger, "request") ]

        assert_equal 0, total(PromptBudget.enforce!(messages, @agent))
      end

      test "bounds other retained text even with an image only trigger" do
        limit!(5)
        image_only = { role: "user", kind: :trigger, parts: [ { image: :blob } ] }
        messages = [ entry(:chat_history, "h" * 20), entry(:system_note, "s" * 20), image_only ]

        result = PromptBudget.enforce!(messages, @agent)

        assert_equal [ :system_note, :trigger ], result.map { |m| m[:kind] }
        assert_equal "s" * 5, result.first.dig(:parts, 0, :text)
      end
    end
  end
end
