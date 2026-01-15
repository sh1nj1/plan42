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
    end

    def build(collection, level: 1)
      return [] if collection.blank?

      build_nodes(Array(collection), level: level)
    end

    private

    attr_reader :user, :view_context, :raw_params, :expanded_state_map, :select_mode, :max_level, :allowed_creative_ids, :progress_map

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
          link_url: view_context.creative_path(creative),
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

      # Include virtually linked children (origins from CreativeLinks)
      linked_origins = Creative.joins(:parent_links)
        .where(creative_links: { parent_id: creative.id })
        .select { |c| c.has_permission?(user, :read) }

      children = (actual_children + linked_origins).uniq

      if allowed_creative_ids
        children.select { |c| allowed_creative_ids.include?(c.id.to_s) }
      else
        children
      end
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

      {
        id: "creative-children-#{creative.id}",
        expanded: expanded,
        loaded: load_children_now,
        load_url: view_context.children_creative_path(
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
        view_context.creative_path(creative.origin),
        class: "creative-origin-link creative-action-btn unstyled-link",
        title: I18n.t("creatives.index.view_origin"),
        aria: { label: I18n.t("creatives.index.view_origin") }
      ) do
        view_context.svg_tag("arrow-right.svg", class: "creative-origin-link-icon", width: 16, height: 16)
      end
    end
  end
end
