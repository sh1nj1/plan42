module Collavre
  module Creatives
    # Breadth-first rendered paths keep ancestors ahead of linked descendants.
    class WorkspaceExpansionOrder
      # Keep aligned with MAX_EXPANDED_BRANCHES in workspace_tree_controller.js.
      RESTORE_LIMIT = 100
      # Bound permission/indexing work even when saved branches have become leaves.
      INSPECTION_LIMIT = 1_000

      def initialize(user:, expanded_ids:)
        @user = user
        @expanded_ids = expanded_ids.to_set
        @children_index = ChildrenIndex.new(user: user, show_archived: false)
      end

      def call
        return [] if @expanded_ids.empty?

        roots = Creative.active.where(user: @user, id: @expanded_ids.to_a).roots.limit(INSPECTION_LIMIT).pluck(:id)
        pending = roots.map { |id| [ id, Set.new ] }
        restored = Set.new
        remaining = INSPECTION_LIMIT
        until pending.empty? || restored.size >= RESTORE_LIMIT || remaining.zero?
          batch = pending.shift([ RESTORE_LIMIT - restored.size, remaining ].min)
          remaining -= batch.size
          append_branches(batch, restored, pending)
        end
        restored.to_a
      end

      private

      def append_branches(entries, restored, next_level)
        ids = entries.map(&:first)
        readable = PermissionFilter.new(user: @user).readable_ids(ids)
        creatives = Creative.where(id: readable).includes(:origin).index_by(&:id)
        @children_index.index(creatives.values)
        entries.each do |id, ancestors|
          creative = creatives[id]
          next unless creative

          path = ancestors.dup.add(id)
          children = @children_index.child_ids(creative).reject { |child_id| path.include?(child_id) }
          next if children.empty?

          restored.add(id.to_s)
          children.each do |child_id|
            break if next_level.size >= INSPECTION_LIMIT

            next_level << [ child_id, path ] if @expanded_ids.include?(child_id.to_s)
          end
        end
      end
    end
  end
end
