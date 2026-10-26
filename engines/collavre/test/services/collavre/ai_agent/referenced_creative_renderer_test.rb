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

      private

      def render
        ReferencedCreativeRenderer.new(agent: @agent, max_depth: 1, prune: ->(_) { false }, ancestry: ->(_) { "root" })
                                  .render(@creative)
      end
    end
  end
end
