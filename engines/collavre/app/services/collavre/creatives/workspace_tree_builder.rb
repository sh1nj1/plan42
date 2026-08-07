module Collavre
  module Creatives
    class WorkspaceTreeBuilder
      def initialize(user:, view_context:, max_level:)
        @user = user
        @view_context = view_context
        @max_level = max_level
        @children_index = ChildrenIndex.new(user: user, show_archived: false)
        @permission_rank = {}
      end

      def build(collection, level: 1)
        creatives = Array(collection)
        return [] if creatives.empty? || level > max_level

        prepare_level(creatives)
        branches = creatives.select { |creative| children_index.has_children?(creative) }
        children_index.load(branches)

        branches.map do |creative|
          {
            id: creative.id,
            label: Collavre::HtmlText.label(creative.effective_description),
            snippet: creative.creative_snippet,
            can_comment: allowed?(creative, :feedback),
            url: view_context.collavre.creatives_path(id: creative.id),
            children: build(children_index.children_for(creative), level: level + 1)
          }
        end
      end

      private

      attr_reader :children_index, :max_level, :user, :view_context

      def prepare_level(creatives)
        ActiveRecord::Associations::Preloader.new(records: creatives, associations: :origin).call
        preload_permissions(creatives)
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
