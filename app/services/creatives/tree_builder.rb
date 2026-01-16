module Creatives
  class TreeBuilder
    FILTER_IGNORED_KEYS = %w[id controller action format level select_mode link_parent_id].freeze

    def initialize(user:, params:, view_context:, expanded_state_map:, select_mode:, max_level:, allowed_creative_ids: nil, progress_map: nil, link_parent_id: nil, parent_id: nil)
      @user = user
      @view_context = view_context
      @raw_params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @expanded_state_map = expanded_state_map || {}
      @select_mode = select_mode
      @max_level = max_level
      @allowed_creative_ids = allowed_creative_ids
      @progress_map = progress_map
      @link_parent_id = link_parent_id
      @parent_id = parent_id
    end

    def build(collection, level: 1)
      return [] if collection.blank?

      # Pre-populate link map for creatives that are linked origins of the parent
      # Only mark as linked if NOT a direct child of this parent
      # Stores { origin_id => { id: link_id, parent_id: parent_id } } to avoid N+1 queries
      if @parent_id
        direct_child_ids = Creative.where(parent_id: @parent_id).pluck(:id).to_set
        CreativeLink.where(parent_id: @parent_id).each do |link|
          next if direct_child_ids.include?(link.origin_id)
          @linked_origin_link_map ||= {}
          @linked_origin_link_map[link.origin_id] = { id: link.id, parent_id: link.parent_id }
        end
      end

      build_nodes(Array(collection), level: level)
    end

    private

    attr_reader :user, :view_context, :raw_params, :expanded_state_map, :select_mode, :max_level, :allowed_creative_ids, :progress_map, :link_parent_id

    def build_nodes(creatives, level:)
      return [] if level > max_level

      creatives.flat_map do |creative|
        build_nodes_for_creative(creative, level: level)
      end
    end

    def build_nodes_for_creative(creative, level:)
      if progress_map && progress_map.key?(creative.id.to_s)
        creative.filtered_progress = progress_map[creative.id.to_s]
      end

      filtered_children = filtered_children_for(creative)
      expanded = expanded?(creative.id)
      skip = skip_creative?(creative)
      child_level = level + 1
      child_render_level = skip ? level : child_level
      load_children_now = filters_applied? || expanded || skip
      children_nodes = load_children_now ? build_nodes(filtered_children, level: child_render_level) : []

      return children_nodes if skip

      link_id = creative_link_id_for(creative)
      [
        {
          id: creative.id,
          dom_id: "creative-#{creative.id}",
          parent_id: creative.parent_id,
          level: level,
          select_mode: !!select_mode,
          can_write: creative.has_permission?(user, :write),
          has_children: filtered_children.any?,
          expanded: expanded,
          is_root: creative.parent.nil?,
          link_url: link_url_for(creative),
          is_linked: link_id.present?,
          link_id: link_id,
          templates: template_payload_for(creative),
          inline_editor_payload: inline_editor_payload_for(creative),
          children_container: children_container_payload(
            creative,
            filtered_children,
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

    def filtered_children_for(creative)
      return [] if raw_params["comment"] == "true" || raw_params["search"].present?

      # Include actual children
      actual_children = creative.children_with_permission(user)
      actual_children_ids = actual_children.map(&:id).to_set

      # Include virtually linked children (origins from CreativeLinks)
      creative_links = CreativeLink.where(parent_id: creative.id).includes(:origin)
      linked_origins = creative_links
        .map(&:origin)
        .compact
        .select { |c| c.has_permission?(user, :read) }

      # Track which creatives are linked origins with their link IDs and parent IDs
      # Only mark as linked if NOT a direct child of this parent
      @linked_origin_link_map ||= {}
      creative_links.each do |link|
        next if actual_children_ids.include?(link.origin_id)
        @linked_origin_link_map[link.origin_id] = { id: link.id, parent_id: link.parent_id }
      end

      children = (actual_children + linked_origins).uniq.sort_by(&:sequence)

      if allowed_creative_ids
        children.select { |c| allowed_creative_ids.include?(c.id.to_s) }
      else
        children
      end
    end

    def creative_link_info_for(creative)
      @linked_origin_link_map ||= {}
      @linked_origin_link_map[creative.id]
    end

    def creative_link_id_for(creative)
      creative_link_info_for(creative)&.dig(:id)
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

    def template_payload_for(creative)
      description_html = view_context.embed_youtube_iframe(creative.effective_description(raw_params["tags"]&.first))
      progress_html = view_context.render_creative_progress(creative, select_mode: !!select_mode)

      {
        description_html: description_html,
        progress_html: progress_html,
        edit_icon_html: edit_icon_html,
        edit_off_icon_html: edit_off_icon_html,
        origin_link_html: origin_link_html_for(creative)
      }
    end

    def inline_editor_payload_for(creative)
      {
        description_raw_html: creative.effective_description(nil, true),
        progress: creative.progress,
        origin_id: creative.origin_id
      }
    end

    def children_container_payload(creative, filtered_children, child_level:, children_nodes:, expanded:, load_children_now:)
      return nil unless filtered_children.any?

      # Check if this creative is a linked origin - if so, use the link context
      link_info = creative_link_info_for(creative)
      effective_link_parent = link_info ? link_info[:parent_id] : link_parent_id

      load_url_params = {
        level: child_level,
        select_mode: select_mode ? 1 : 0
      }
      load_url_params[:link_parent_id] = effective_link_parent if effective_link_parent

      {
        id: "creative-children-#{creative.id}",
        expanded: expanded,
        loaded: load_children_now,
        load_url: view_context.children_creative_path(creative, load_url_params),
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
        view_context.creative_path(creative.origin),
        class: "creative-origin-link creative-action-btn unstyled-link",
        title: I18n.t("creatives.index.view_origin"),
        aria: { label: I18n.t("creatives.index.view_origin") }
      ) do
        view_context.svg_tag("arrow-right.svg", class: "creative-origin-link-icon", width: 16, height: 16)
      end
    end

    def link_url_for(creative)
      # Check if this creative is displayed via a creative_link
      link_id = creative_link_id_for(creative)

      if link_id
        # Use /l/:link_id URL for linked origins
        view_context.creative_link_view_path(link_id)
      elsif link_parent_id
        # We're inside a linked subtree, preserve context
        view_context.creative_path(creative, link_parent_id: link_parent_id)
      else
        view_context.creative_path(creative)
      end
    end
  end
end
