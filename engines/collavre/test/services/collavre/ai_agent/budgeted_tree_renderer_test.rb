# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class BudgetedTreeRendererTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @root = Creative.create!(description: "Tree root", user: @user)
        @child = Creative.create!(description: "Tree child", user: @user, parent: @root)
        Creative.create!(description: "Tree grandchild " + ("g" * 300), user: @user, parent: @child)
      end

      def renderer(max_depth: 7)
        BudgetedTreeRenderer.new(max_depth: max_depth, prune: ->(_) { false })
      end

      def full_markdown
        ApplicationController.helpers.render_creative_tree_markdown([ @root ], 1, true, max_depth: 7)
      end

      test "returns the whole tree untouched when it fits" do
        assert_equal full_markdown, renderer.render(@root, 10_000)
      end

      test "stops at the configured depth without a truncation note" do
        text = renderer(max_depth: 2).render(@root, 10_000)

        assert_includes text, "Tree child"
        refute_includes text, "Tree grandchild"
        refute_includes text, "context budget"
      end

      test "drops the deepest levels that do not fit and says how to read them" do
        budget = full_markdown.length - 1
        text = renderer.render(@root, budget)

        assert_includes text, "Tree child"
        refute_includes text, "Tree grandchild"
        assert_includes text, "Subtree shown to depth 2"
        assert_includes text, "creative_retrieval_service(id: #{@root.id}, level: N)"
        assert_operator text.length, :<=, budget
      end

      test "cuts a root whose own text exceeds the budget" do
        @root.update!(description: "Huge root " + ("r" * 2_000))
        text = renderer.render(@root, 500)

        assert_includes text, "Huge root"
        assert_includes text, "Content truncated to fit the context budget"
        assert_equal 500, text.length
      end

      test "a spent budget leaves only the retrieval note" do
        text = renderer.render(@root, -10)

        refute_includes text, "Tree root"
        assert_includes text, "creative_retrieval_service(id: #{@root.id})"
      end
    end
  end
end
