module Collavre
  module Creatives
    class WorkspaceTreeBuilder
      def initialize(user:, view_context:, expanded_ids: [])
        @user = user
        @view_context = view_context
        @expanded_ids = expanded_ids.map(&:to_s).to_set
        @children_index = ChildrenIndex.new(user: user, show_archived: false)
        @permission_rank = {}
      end

      def build(collection)
        entries = Array(collection).map { |creative| { creative: creative, ancestor_ids: Set.new } }
        build_entries(entries)
      end

      private

      attr_reader :children_index, :expanded_ids, :user, :view_context

      def build_entries(entries)
        return [] if entries.empty?

        creatives = entries.map { |entry| entry.fetch(:creative) }.uniq(&:id)
        prepare_level(creatives)
        children_index.load(creatives)
        children_by_parent = creatives.to_h { |creative| [ creative.id, children_index.children_for(creative) ] }
        prepare_presence(children_by_parent.values.flatten)
        child_entries_by_parent = entries.to_h do |entry|
          creative = entry.fetch(:creative)
          children = expanded?(creative) ? acyclic_children(entry, children_by_parent.fetch(creative.id)) : []
          child_entries = children.map do |child|
            { creative: child, ancestor_ids: entry.fetch(:ancestor_ids).dup.add(creative.id) }
          end
          [ entry.object_id, child_entries ]
        end
        child_nodes = build_entries(child_entries_by_parent.values.flatten)
        next_child_node = child_nodes.each

        entries.map do |entry|
          creative = entry.fetch(:creative)
          visible_children = acyclic_children(entry, children_by_parent.fetch(creative.id))
          children = child_entries_by_parent.fetch(entry.object_id).map { next_child_node.next }
          {
            id: creative.id,
            label: Collavre::HtmlText.label(creative.effective_description),
            snippet: creative.creative_snippet,
            can_comment: allowed?(creative, :feedback),
            url: view_context.collavre.creatives_path(id: creative.id),
            has_children: visible_children.any?,
            children: children
          }
        end
      end

      def acyclic_children(entry, children)
        visited_ids = entry.fetch(:ancestor_ids).dup.add(entry.fetch(:creative).id)
        children.reject { |child| visited_ids.include?(child.id) }
      end

      def expanded?(creative)
        expanded_ids.include?(creative.id.to_s)
      end

      def prepare_level(creatives)
        ActiveRecord::Associations::Preloader.new(records: creatives, associations: :origin).call
        preload_permissions(creatives)
        children_index.index(creatives)
      end

      def prepare_presence(creatives)
        return if creatives.empty?

        ActiveRecord::Associations::Preloader.new(records: creatives, associations: :origin).call
        children_index.index(creatives)
      end

      def preload_permissions(creatives)
        pending = creatives.reject { |creative| @permission_rank.key?(creative.id) }
        return if pending.empty?

        ranks = PermissionFilter.new(user: user).ranks_for(pending.map(&:id))
        pending.each { |creative| @permission_rank[creative.id] = ranks[creative.id] }
      end

      def allowed?(creative, permission)
        rank = @permission_rank[creative.id]
        rank.present? && rank >= CreativeShare.permissions.fetch(permission.to_s)
      end
    end
  end
end
