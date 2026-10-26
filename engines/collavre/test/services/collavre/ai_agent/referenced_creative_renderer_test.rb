# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class ReferencedCreativeRendererTest < ActiveSupport::TestCase
      setup do
        @agent = users(:ai_bot)
        @creative = Creative.create!(description: "Note #{"n" * 50}", user: users(:one), progress: 0.0)
      end

      test "defaults allow an ordinary creative to be inlined" do
        @agent.agent_conf = nil

        assert_includes render, "n" * 50
      end

      test "unset budgets fall back to the defaults" do
        @agent.agent_conf = "context:\n  referenced_creative_size:\n  referenced_creative_total_size:"

        assert_includes render, "n" * 50
      end

      test "string budgets are coerced to integers" do
        @agent.agent_conf = "context:\n  referenced_creative_size: '10'"

        assert_includes render, "not inlined"
      end

      test "a root longer than the limit is carded without rendering its tree" do
        @agent.agent_conf = "context:\n  referenced_creative_size: 10"

        assert_no_tree_render { assert_includes render, "not inlined" }
      end

      test "once a card no longer fits, later links skip straight to the overflow note" do
        @agent.agent_conf = "context:\n  referenced_creative_size: 10\n  referenced_creative_total_size: 250"
        renderer = build_renderer
        other = Creative.create!(description: "Other", user: users(:one), progress: 0.0)

        assert_nil renderer.render(@creative)
        assert_no_tree_render { assert_nil renderer.render(other) }
        assert_includes renderer.overflow_note, "id: #{@creative.id}, id: #{other.id}"
      end

      test "the overflow note truncates its id list to stay within the total budget" do
        @agent.agent_conf = "context:\n  referenced_creative_size: 10\n  referenced_creative_total_size: 300"
        renderer = build_renderer
        creatives = Array.new(2_000) { |i| Creative.new(id: 1_000_000 + i, description: "Doc #{"d" * 50}") }
        texts = creatives.filter_map { |c| renderer.render(c) }
        note = renderer.overflow_note

        assert_includes note, "id: 1000000, id: 1000001"
        assert_match(/, and \d+ more\n/, note)
        assert_operator texts.sum(&:length) + note.length, :<=, 300
      end

      test "a budget too small for any id still reports the deferred count" do
        @agent.agent_conf = "context:\n  referenced_creative_size: 10\n  referenced_creative_total_size: 140"
        renderer = build_renderer
        renderer.render(@creative)

        assert_includes renderer.overflow_note, "not shown (context budget spent): and 1 more\n"
      end

      test "no overflow note while everything fit" do
        @agent.agent_conf = nil
        renderer = build_renderer
        renderer.render(@creative)

        assert_nil renderer.overflow_note
      end

      private

      def build_renderer
        ReferencedCreativeRenderer.new(agent: @agent, max_depth: 1, prune: ->(_) { false }, ancestry: ->(_) { "root" })
      end

      def render
        build_renderer.render(@creative)
      end

      def assert_no_tree_render(&block)
        ApplicationController.helpers.stub(:render_creative_tree_markdown, ->(*) { flunk "tree rendered" }, &block)
      end
    end
  end
end
