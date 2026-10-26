# frozen_string_literal: true

module Collavre
  module AiAgent
    # Renders creatives linked from chat into prompt text under a character
    # budget. A creative that fits the per-link and remaining per-turn budget
    # is inlined; a larger one is announced as a reference card so the agent
    # fetches it on demand, and one long document or a handful of links
    # cannot overflow the prompt.
    #
    # Budgets come from agent_conf `context.referenced_creative_size` and
    # `context.referenced_creative_total_size`. Call #render in priority order:
    # earlier links claim the budget first.
    class ReferencedCreativeRenderer
      DEFAULT_SIZE = 4_000
      DEFAULT_TOTAL_SIZE = 12_000

      def initialize(agent:, max_depth:, prune:, ancestry:)
        conf = agent.parsed_agent_conf["context"].to_h
        @per_link = (conf["referenced_creative_size"] || DEFAULT_SIZE).to_i
        @remaining = (conf["referenced_creative_total_size"] || DEFAULT_TOTAL_SIZE).to_i
        @max_depth = max_depth
        @prune = prune
        @ancestry = ancestry
      end

      def render(creative)
        markdown = ApplicationController.helpers.render_creative_tree_markdown(
          [ creative ], 1, true, max_depth: @max_depth, prune: @prune
        )
        return card(creative, markdown.length) if markdown.length > [ @per_link, @remaining ].min

        @remaining -= markdown.length
        "Referenced Creative (id: #{creative.id}):\n#{markdown}"
      end

      private

      def card(creative, size)
        children = creative.effective_origin(Set.new).children.count
        "Referenced Creative (id: #{creative.id}) — not inlined (~#{size} chars, #{children} children)\n" \
          "Path: #{@ancestry.call(creative)}\n" \
          "Use creative_retrieval_service(id: #{creative.id}) to read its content when needed."
      end
    end
  end
end
