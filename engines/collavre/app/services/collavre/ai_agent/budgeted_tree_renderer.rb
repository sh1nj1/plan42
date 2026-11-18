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
    # Rendering a level is abandoned as soon as the plain text of the nodes
    # visited so far exceeds the budget (rendered markdown is never shorter
    # than its plain text), so an oversized level costs about one budget's
    # worth of nodes rather than the whole level.
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
          markdown = render_tree(creative, depth, limit)
          if markdown.nil? || markdown.length > limit
            return fitting + truncation_note(creative, depth - 1) if fitting

            return cut_root(creative, budget)
          end
          # Same text one level deeper: the whole tree is already shown.
          return markdown if fitting && markdown.length == fitting.length

          fitting = markdown
        end

        fitting
      end

      private

      # The tree to +depth+, or nil once it is known to exceed +limit+.
      def render_tree(creative, depth, limit = nil)
        visited = 0
        prune = lambda do |node|
          next true if @prune.call(node)

          visited += plain_length(node) if limit
          throw :over_budget if limit && visited > limit
          false
        end
        catch(:over_budget) do
          return ApplicationController.helpers.render_creative_tree_markdown(
            [ creative ], 1, true, max_depth: depth, prune: prune
          )
        end
        nil
      end

      def plain_length(creative)
        ActionView::Base.full_sanitizer.sanitize(creative.effective_description(nil, true).to_s).squish.length
      end

      def cut_root(creative, budget)
        markdown = render_tree(creative, 1)
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
