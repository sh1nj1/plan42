module Collavre
module Creatives
  class TreeBuilder
    FILTER_IGNORED_KEYS = %w[id controller action format level select_mode].freeze

    def initialize(user:, params:, view_context:, expanded_state_map:, select_mode:, max_level:, allowed_creative_ids: nil, progress_map: nil)
      @user = user
      @view_context = view_context
      @raw_params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @expanded_state_map = expanded_state_map || {}
      @select_mode = select_mode
      @max_level = max_level
      @allowed_creative_ids = allowed_creative_ids
      @progress_map = progress_map
      @permission_rank = {}
    end

    def build(collection, level: 1)
      return [] if collection.blank?

      build_nodes(Array(collection), level: level)
    end

    private

    attr_reader :user, :view_context, :raw_params, :expanded_state_map, :select_mode, :max_level, :allowed_creative_ids, :progress_map

    def children_index
      @children_index ||= ChildrenIndex.new(
        user: user,
        show_archived: raw_params["show_archived"].present?,
        allowed_creative_ids: allowed_creative_ids
      )
    end

    def comment_badge_index
      @comment_badge_index ||= CommentBadgeIndex.new(user: user)
    end

    # Everything a level of nodes needs, resolved in a fixed number of queries
    # rather than a handful per node. The recursion re-enters here for each level,
    # so total cost tracks tree *depth*, not node count.
    def prepare_level(creatives)
      ActiveRecord::Associations::Preloader.new(
        records: creatives,
        associations: [ :origin, { tags: :label } ]
      ).call

      preload_permissions(creatives)
      preload_comment_badges(creatives)

      return if children_suppressed?

      children_index.index(creatives)
      expanding = creatives.select { |creative| load_children_now?(creative) }
      children_index.load(expanding) if expanding.any?
    end

    # Batch effective-origin permission ranks via the single PermissionFilter
    # read path (owner wins, then the user's own cache entry incl. a no_access
    # deny, then the public entry). Every pending creative gets an explicit
    # entry — nil when no share resolves — so #allowed? can trust
    # @permission_rank.key? and never falls back per-item for absent ids.
    def preload_permissions(creatives)
      pending = creatives.reject { |creative| @permission_rank.key?(creative.id) }
      return if pending.empty?

      ranks = PermissionFilter.new(user: user).ranks_for(pending.map(&:id))
      pending.each { |creative| @permission_rank[creative.id] = ranks[creative.id] }
    end

    # Equivalent to `creative.has_permission?(user, permission)`, served from the
    # level's batched ranks. Falls back for a creative the batch never saw.
    def allowed?(creative, permission)
      return creative.has_permission?(user, permission) unless @permission_rank.key?(creative.id)

      rank = @permission_rank[creative.id]
      return false if rank.nil?

      rank >= CreativeShare.permissions[permission.to_s]
    end

    def can_write?(creative)
      return false unless user
      # Read-only-source creatives are never writable
      return false if creative.read_only_source?

      allowed?(creative, :write)
    end

    def can_feedback?(creative)
      allowed?(creative, :feedback)
    end

    # Only rows that will actually render a badge are worth batching.
    def preload_comment_badges(creatives)
      visible = creatives.reject(&:archived?).select { |creative| can_feedback?(creative) }
      return if visible.empty?

      comment_badge_index.index(visible.map(&:effective_origin))
    end

    def build_nodes(creatives, level:)
      return [] if level > max_level
      return [] if creatives.empty?

      prepare_level(creatives)

      creatives.flat_map do |creative|
        build_nodes_for_creative(creative, level: level)
      end
    end

    def build_nodes_for_creative(creative, level:)
      if progress_map && progress_map.key?(creative.id.to_s)
        creative.filtered_progress = progress_map[creative.id.to_s]
      end

      expanded = expanded?(creative.id)
      skip = skip_creative?(creative)
      child_level = level + 1
      child_render_level = skip ? level : child_level
      load_children_now = load_children_now?(creative)
      has_children = !children_suppressed? && children_index.has_children?(creative)
      children_nodes = load_children_now ? build_nodes(children_index.children_for(creative), level: child_render_level) : []

      return children_nodes if skip

      can_write = can_write?(creative)

      [
        {
          id: creative.id,
          dom_id: "creative-#{creative.id}",
          parent_id: creative.parent_id,
          level: level,
          select_mode: !!select_mode,
          can_write: can_write,
          has_children: has_children,
          expanded: expanded,
          is_root: creative.parent_id.nil?,
          archived: creative.archived?,
          # `github_source` is the wire key the tree renderer JS reads; its value
          # is now the neutral read-only-source flag (GitHub-synced content is one
          # such source) so core names no vendor here.
          github_source: creative.read_only_source?,
          sequence: creative.sequence,
          link_url: view_context.collavre.creative_path(creative),
          templates: template_payload_for(creative, has_children: has_children, can_write: can_write),
          inline_editor_payload: inline_editor_payload_for(creative, can_write: can_write),
          children_container: children_container_payload(
            creative,
            has_children: has_children,
            child_level: child_level,
            children_nodes: children_nodes,
            expanded: expanded,
            load_children_now: load_children_now
          )
        }
      ]
    end

    def skip_creative?(creative)
      # With FilterPipeline, allowed_creative_ids contains all creatives that should be shown
      # (matched items + their ancestors). No need for duplicate filter logic here.
      return !allowed_creative_ids.include?(creative.id.to_s) if allowed_creative_ids

      false
    end

    # The chats feed and flat search render rows, not a tree: no node has children
    # there, so the whole child resolution is skipped.
    def children_suppressed?
      return @children_suppressed if defined?(@children_suppressed)

      @children_suppressed = raw_params["comment"] == "true" ||
        (raw_params["search"].present? && raw_params["search_mode"] != "tree")
    end

    def load_children_now?(creative)
      filters_applied? || expanded?(creative.id) || skip_creative?(creative)
    end

    def expanded?(creative_id)
      expanded_state_map[creative_id.to_s].present?
    end

    def filters_applied?
      @filters_applied ||= begin
        return true if allowed_creative_ids.present?

        filtered = raw_params.except(*FILTER_IGNORED_KEYS)
        filtered.present?
      end
    end

    def template_payload_for(creative, has_children: nil, can_write: nil)
      description_html = view_context.embed_youtube_iframe(creative.effective_description(raw_params["tags"]&.first))
      can_feedback = can_feedback?(creative)
      progress_html = view_context.render_creative_progress(
        creative,
        select_mode: !!select_mode,
        has_children: has_children,
        can_write: can_write,
        can_feedback: can_feedback,
        unread_count: can_feedback ? comment_badge_index.unread_count_for(creative.effective_origin) : nil
      )

      {
        description_html: description_html,
        progress_html: progress_html,
        edit_icon_html: edit_icon_html,
        edit_off_icon_html: edit_off_icon_html,
        origin_link_html: origin_link_html_for(creative)
      }
    end

    def inline_editor_payload_for(creative, can_write:)
      effective = creative.effective_origin(Set.new)
      origin_writable = effective.id == creative.id ? can_write : allowed?(creative, :write)
      {
        description_raw_html: creative.effective_description(nil, true),
        progress: creative.progress,
        origin_id: creative.origin_id,
        content_type: effective.data&.dig("content_type"),
        markdown_source: origin_writable ? effective.data&.dig("markdown_source") : nil,
        markdown_editor: effective.data&.dig("editor")
      }
    end

    def children_container_payload(creative, has_children:, child_level:, children_nodes:, expanded:, load_children_now:)
      return nil unless has_children

      {
        id: "creative-children-#{creative.id}",
        expanded: expanded,
        loaded: load_children_now,
        load_url: view_context.collavre.children_creative_path(
          creative,
          level: child_level,
          select_mode: select_mode ? 1 : 0
        ),
        level: child_level,
        nodes: children_nodes
      }
    end

    def edit_icon_html
      @edit_icon_html ||= view_context.svg_tag("edit.svg", className: "icon-edit")
    end

    def edit_off_icon_html
      @edit_off_icon_html ||= view_context.svg_tag("edit-off.svg", className: "icon-edit")
    end

    def origin_link_html_for(creative)
      return unless creative.origin_id.present?

      view_context.link_to(
        view_context.collavre.creative_path(creative.origin),
        class: "creative-origin-link creative-action-btn unstyled-link",
        title: I18n.t("collavre.creatives.index.view_origin"),
        aria: { label: I18n.t("collavre.creatives.index.view_origin") }
      ) do
        view_context.svg_tag("arrow-right.svg", class: "creative-origin-link-icon", width: 16, height: 16)
      end
    end
  end
end
end
