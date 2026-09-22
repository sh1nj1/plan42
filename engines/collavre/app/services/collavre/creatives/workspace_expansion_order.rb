module Collavre
  module Creatives
    # Walk the rendered graph, not physical hierarchy depths: linked shells
    # display their origin's children. Only saved, reachable branches count.
    class WorkspaceExpansionOrder
      def initialize(user:, expanded_ids:)
        @user = user
        @expanded_ids = expanded_ids.to_set
        # Unsaved children still make a saved parent expandable.
        @children_index = ChildrenIndex.new(
          user: user, show_archived: false
        )
      end

      def call
        return [] if @expanded_ids.empty?

        roots = Creative.active.where(user: @user, parent_id: nil, id: @expanded_ids.to_a)
        readable = PermissionFilter.new(user: @user).readable_ids(roots.pluck(:id))
        level = roots.where(id: readable).to_a
        visited = Set.new
        until level.empty?
          children = children_of(level)
          level.each { |creative| visited.add(creative.id.to_s) if @children_index.has_children?(creative) }
          level = children.uniq(&:id).select do |creative|
            @expanded_ids.include?(creative.id.to_s) && !visited.include?(creative.id.to_s)
          end
        end
        visited.to_a
      end

      private

      def children_of(level)
        ActiveRecord::Associations::Preloader.new(records: level, associations: :origin).call
        @children_index.index(level)
        @children_index.load(level)
        level.flat_map { |creative| @children_index.children_for(creative) }
      end
    end
  end
end
