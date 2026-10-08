# frozen_string_literal: true

module Collavre
  module Creatives
    # Builds the subtree an anonymous reader may see under a public creative, for
    # server-rendered public pages.
    #
    # Permission is always resolved for the anonymous reader (user: nil) — never
    # the signed-in visitor — so a public page cannot leak private content to
    # whoever happens to be looking. Linked creatives contribute their origin's
    # content and children, and PermissionFilter already hides a link whose
    # origin is not public.
    #
    # The walk is breadth-first with one children query and one permission batch
    # per level, and stops at `limit` nodes or `max_depth` levels so a huge tree
    # cannot make the page unbounded. `truncated?` reports whether anything was
    # left out.
    class PublicTreeBuilder
      Node = Struct.new(:creative, :children)

      DEFAULT_LIMIT = 500
      DEFAULT_MAX_DEPTH = 8

      def initialize(root, limit: DEFAULT_LIMIT, max_depth: DEFAULT_MAX_DEPTH)
        @root = root.effective_origin
        @limit = limit
        @max_depth = max_depth
        @truncated = false
      end

      def truncated?
        @truncated
      end

      def call
        nodes = []
        frontier = { @root.id => nodes }
        expanded = Set[@root.id]
        count = 0

        @max_depth.times do
          break if frontier.empty?

          next_frontier = {}
          readable_children(frontier.keys).each do |child|
            if count >= @limit
              @truncated = true
              break
            end

            node = Node.new(child.effective_origin, [])
            frontier[child.parent_id] << node
            count += 1

            # A creative linked in more than once (or a link back up the tree)
            # is listed each time but expanded only once.
            origin_id = node.creative.id
            next if expanded.include?(origin_id)

            expanded << origin_id
            next_frontier[origin_id] = node.children
          end
          frontier = next_frontier
        end

        @truncated ||= frontier.any? && Creative.active.where(parent_id: frontier.keys).exists?
        nodes
      end

      private

      def readable_children(parent_ids)
        children = Creative.active.where(parent_id: parent_ids).includes(:origin).order(:sequence, :id).to_a
        readable = PermissionFilter.new(user: nil).readable_ids(children.map(&:id)).to_set
        children.select { |child| readable.include?(child.id) }
      end
    end
  end
end
