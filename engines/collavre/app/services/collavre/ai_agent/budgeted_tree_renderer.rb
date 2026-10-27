# frozen_string_literal: true

module Collavre
  module AiAgent
    # Renders a creative subtree into prompt markdown no longer than a
    # character budget. The tree is rendered one level deeper at a time and
    # the deepest level that fits is kept, so a wide tree (thousands of issue
    # children) loses its lower levels instead of blowing up the whole prompt.
    # A root whose own text exceeds the budget is cut to the budget. Either way
    # the output ends with a note telling the agent how to read the rest.
    #
    # Rendering bottom-up stops at the first level that overflows, so the cost
    # is bounded by the budget plus one level, never the full configured depth.
    class BudgetedTreeRenderer
      def initialize(max_depth:, prune:)
        @max_depth = max_depth
        @prune = prune
      end

      # Markdown for +creative+ within +budget+ characters, note included.
      def render(creative, budget)
        limit = budget - truncation_note(creative, @max_depth).length
        fitting = nil

        1.upto(@max_depth) do |depth|
          markdown = render_tree(creative, depth)
          # Same text one level deeper: the whole tree is already shown.
          return markdown if fitting && markdown.length == fitting.length
          if markdown.length > limit
            return fitting ? fitting + truncation_note(creative, depth - 1) : cut_root(creative, markdown, budget)
          end

          fitting = markdown
        end

        fitting
      end

      private

      def render_tree(creative, depth)
        ApplicationController.helpers.render_creative_tree_markdown(
          [ creative ], 1, true, max_depth: depth, prune: @prune
        )
      end

      def cut_root(creative, markdown, budget)
        note = "\n\n(Content truncated to fit the context budget. " \
               "Use creative_retrieval_service(id: #{creative.id}) to read it in full.)"
        "#{markdown[0, [ budget - note.length, 0 ].max]}#{note}"
      end

      def truncation_note(creative, shown_depth)
        "\n(Subtree shown to depth #{shown_depth} to fit the context budget. " \
          "Use creative_retrieval_service(id: #{creative.id}, level: N) to read deeper levels.)"
      end
    end
  end
end
