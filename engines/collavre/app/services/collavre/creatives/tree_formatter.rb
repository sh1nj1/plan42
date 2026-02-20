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
    #
    # Options:
    #   max_depth:        Max tree depth (nil = unlimited)
    #   include_header:   Include format comment header (default: true)
    #   include_comments: Include recent comments per node (default: false)
    #   use_permissions:  Use permission-filtered children (default: true)
    class TreeFormatter
      def initialize(max_depth: nil, include_header: true, include_comments: false, use_permissions: true)
        @max_depth = max_depth
        @include_header = include_header
        @include_comments = include_comments
        @use_permissions = use_permissions
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

      # Extract plain text description from a creative (shared helper)
      def self.plain_description(creative)
        raw = creative.effective_description(nil, true)
        ActionView::Base.full_sanitizer.sanitize(raw).strip
      end

      private

      def format_node(node, depth, lines)
        return if @max_depth && depth > @max_depth

        indent = "  " * depth
        desc = self.class.plain_description(node)
        progress = ((node.progress || 0.0) * 100).round

        lines << "#{indent}- [#{node.id}] #{desc} (#{progress}%)"

        if @include_comments
          node.comments.order(created_at: :desc).limit(3).reverse_each do |comment|
            comment_text = ActionView::Base.full_sanitizer.sanitize(comment.content).strip.truncate(100)
            lines << "#{indent}    > #{comment_text}"
          end
        end

        children_for(node).each do |child|
          format_node(child, depth + 1, lines)
        end
      end

      def children_for(node)
        if @use_permissions
          node.linked_children
        else
          # When children are pre-set on association target (e.g. GeminiParentRecommender)
          node.children
        end
      end
    end
  end
end
