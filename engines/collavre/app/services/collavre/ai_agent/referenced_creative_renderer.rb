# frozen_string_literal: true

module Collavre
  module AiAgent
    # Renders creatives linked from chat into prompt text under a character
    # budget. A creative that fits the per-link and remaining per-turn budget
    # is inlined; a larger one is announced as a reference card so the agent
    # fetches it on demand. Cards are charged against the same budget, and
    # links left once even a card no longer fits are listed by id in
    # #overflow_note, so neither one long document nor many links can
    # overflow the prompt.
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
        @overflow_ids = []
      end

      # Prompt text for the creative, or nil when the budget is spent and the
      # creative is deferred to #overflow_note.
      def render(creative)
        if @overflow_ids.empty?
          markdown = inline_markdown(creative, [ @per_link, @remaining ].min)
          return charge("Referenced Creative (id: #{creative.id}):\n#{markdown}") if markdown

          text = card(creative)
          return charge(text) if text.length <= @remaining
        end

        @overflow_ids << creative.id
        nil
      end

      def overflow_note
        return if @overflow_ids.empty?

        "Further referenced creatives not shown (context budget spent): " \
          "#{@overflow_ids.map { |id| "id: #{id}" }.join(', ')}\n" \
          "Use creative_retrieval_service(id: N) to read them when needed."
      end

      private

      def charge(text)
        @remaining -= text.length
        text
      end

      # The rendered tree, or nil when it would not fit +limit+. The root's own
      # text is a lower bound on the tree, so a root that alone exceeds the
      # limit skips rendering (and loading) the subtree.
      def inline_markdown(creative, limit)
        return if limit <= 0 || plain_description(creative).length > limit

        markdown = ApplicationController.helpers.render_creative_tree_markdown(
          [ creative ], 1, true, max_depth: @max_depth, prune: @prune
        )
        markdown if markdown.length <= limit
      end

      def plain_description(creative)
        ActionView::Base.full_sanitizer.sanitize(creative.effective_description(nil, true).to_s).strip
      end

      def card(creative)
        children = creative.effective_origin(Set.new).children.count
        "Referenced Creative (id: #{creative.id}) — not inlined (exceeds context budget, #{children} children)\n" \
          "Path: #{@ancestry.call(creative)}\n" \
          "Use creative_retrieval_service(id: #{creative.id}) to read its content when needed."
      end
    end
  end
end
