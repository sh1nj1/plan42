module Collavre
  module Creatives
    class WorkspaceTreeBuilder
      def initialize(user:, view_context:, max_level:)
        @user = user
        @view_context = view_context
        @max_level = max_level
        @children_index = ChildrenIndex.new(user: user, show_archived: false)
      end

      def build(collection, level: 1)
        creatives = Array(collection)
        return [] if creatives.empty? || level > max_level

        children_index.index(creatives)
        branches = creatives.select { |creative| children_index.has_children?(creative) }
        children_index.load(branches)

        branches.map do |creative|
          {
            id: creative.id,
            label: view_context.strip_tags(creative.effective_description).squish,
            url: view_context.collavre.creative_path(creative),
            children: build(children_index.children_for(creative), level: level + 1)
          }
        end
      end

      private

      attr_reader :children_index, :max_level, :view_context
    end
  end
end
