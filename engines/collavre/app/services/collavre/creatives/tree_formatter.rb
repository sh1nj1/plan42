module Collavre
  module Creatives
    # Compact markdown tree formatter for AI Agent consumption.
    # Used by: creative_retrieval_service, GeminiParentRecommender, Agent context injection.
    #
    # Output format (header declared once, rows are values only):
    #   <!-- format: [id] description (progress%) -->
    #   - [123] My Task (50%)
    #     - [124] Subtask A (100%)
    #     - [125] Subtask B (0%)
    class TreeFormatter
      def initialize(max_depth: nil, include_header: true)
        @max_depth = max_depth
        @include_header = include_header
      end

      def format(creatives)
        roots = Array(creatives)
        lines = []
        lines << "<!-- format: [id] description (progress%) -->" if @include_header

        roots.each do |root|
          format_node(root, 0, lines)
        end

        lines.join("\n")
      end

      private

      def format_node(node, depth, lines)
        return if @max_depth && depth > @max_depth

        indent = "  " * depth
        desc = ActionController::Base.helpers.strip_tags(node.effective_description(nil, false))
        progress = ((node.progress || 0.0) * 100).round

        lines << "#{indent}- [#{node.id}] #{desc} (#{progress}%)"

        node.children.each do |child|
          format_node(child, depth + 1, lines)
        end
      end
    end
  end
end
