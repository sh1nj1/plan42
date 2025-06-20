module CreativesHelper
  # Shared toggle button symbol helper
  def toggle_button_symbol(expanded: false)
    expanded ? "\u25BC" : "\u25B6" # ▼ or ▶
  end

  def render_tags(labels, class_name = nil, name_only = false)
    return "" if labels&.empty? or labels.nil?

    index = 0
    safe_join(labels.map do |label|
      suffix = " 🗓#{label.target_date}" if label.type == "Plan" and !name_only
      index += 1
      content_tag(:span, class: "tag") do
        (index == 1 ? "" : " ").html_safe +
        link_to("##{label.name}", creatives_path(tags: [ label.id ]), class: class_name ? class_name: "", title: label.name) + suffix
      end
    end)
  end

  def render_creative_tags(creative)
    labels = creative.tags&.includes(:label)&.map(&:label)&.compact
    return "" if labels&.empty?
    content_tag(:div, class: "creative-tags", style: "display: none;") do
      render_tags(labels, "unstyled-link", true)
    end
  end

  def render_creative_progress(creative, select_mode: false)
    progress_value = if params[:tags].present?
      tag_ids = Array(params[:tags]).map(&:to_s)
      creative.progress_for_tags(tag_ids) || 0
    else
      creative.progress
    end

    content_tag(:div, class: "creative-row-end") do
      comment_part = if creative.has_permission?(Current.user, :feedback)
        comments_count = creative.effective_origin.comments.size
        classes = [ "comments-btn" ]
        classes << "no-comments" if comments_count.zero?
        badge = render(Inbox::BadgeComponent.new(count: comments_count, badge_id: "comment-badge-#{creative.id}"))
        button_tag(
          "\u{1F4AC}".html_safe + badge,
          name: "show-comments-btn",
          data: { creative_id: creative.id, can_comment: true },
          class: classes.join(" ")
        )
      else
        "".html_safe
      end
      render_progress_value(progress_value) + comment_part + "<br />".html_safe + (creative.tags ? render_creative_tags(creative) : "".html_safe)
    end
  end

  def render_progress_value(value)
    content_tag(
      :span,
      number_to_percentage(value * 100, precision: 0),
      class: "creative-progress-#{value == 1 ? 'complete' : 'incomplete'}"
    )
  end

  def render_creative_tree(creatives, level = 1, select_mode: false, max_level: User::DEFAULT_DISPLAY_LEVEL)
    return "".html_safe if level > max_level
    safe_join(
      creatives.map do |creative|
        filtered_children = creative.children_with_permission(Current.user)
        expanded = expanded_from_expanded_state(creative.id, @expanded_state_map)
        render_next_block = ->(level) {
          filters = params.to_unsafe_h.except(:id).present?
          ((filtered_children.any?) ? content_tag(:div, id: "creative-children-#{creative.id}", class: "creative-children", style: "#{filters || expanded ? "" : "display: none;"}", data: { expanded: expanded }) {
            render_creative_tree(filtered_children, level, select_mode: select_mode, max_level: max_level)
          }: "".html_safe)
        }

        skip = false
        if not skip and params[:tags].present?
          tag_ids = Array(params[:tags]).map(&:to_s)
          creative_label_ids = creative.tags.pluck(:label_id).map(&:to_s)
          skip = (creative_label_ids & tag_ids).empty?
        end
        if not skip and params[:min_progress].present?
          min_progress = params[:min_progress].to_f
          skip = creative.progress < min_progress
        end
        if not skip and params[:max_progress].present?
          max_progress = params[:max_progress].to_f
          skip = creative.progress > max_progress
        end

        if skip
          render_next_block.call level # skip this creative, so decrease level
        else
          bullet_starting_level = 3
          renderer = ->(&block) {
            if level <= bullet_starting_level
              heading_tag = (filtered_children.any? or creative.parent.nil?) ? "h#{level}" : "div"
              content_tag(heading_tag, class: "indent#{level}") do
                block.call
              end
            else # low level creative render as li
              margin = level > 0 ? "margin-left: #{(level - bullet_starting_level) * 20}px;" : ""
              content_tag(:div, class: "creative-tree-li", style: "#{margin}") do
                if creative.effective_description.include?("<li>")
                  "".html_safe
                else
                  content_tag(:div, "", class: "creative-tree-bullet")
                end + block.call
              end
            end
          }
          render(CreativeComponent.new(
            creative: creative,
            filtered_children: filtered_children,
            level: level,
            select_mode: select_mode,
            expanded: expanded
          )) do
            renderer.call do
              link_to(creative.effective_description(params[:tags]&.first), creative, class: "unstyled-link")
            end
          end + render_next_block.call(level + 1)
        end
      end
    )
  end

  # parent_creative.expandedState[creative.id] 값 사용, parent_creative가 nil이면 controller에서 내려준 expanded_state_map[nil] 사용
  def expanded_from_expanded_state(creative_id, expanded_state_map)
    !(expanded_state_map and expanded_state_map[creative_id.to_s] == false)
  end

  # 트리 구조를 마크다운으로 변환하는 헬퍼
  # creatives: 트리 배열, level: 현재 깊이(1부터 시작)
  def render_creative_tree_markdown(creatives, level = 1)
    return "" if creatives.blank?
    md = ""
    creatives.each do |creative|
      desc = creative.effective_description(nil, false)
      html = desc.to_s.gsub(/<!--.*?-->/m, "").strip
      html = html_links_to_markdown(html)
      if level <= 4
        md += "#{'#' * level} #{ActionView::Base.full_sanitizer.sanitize(html)}\n\n"
      else
        # trix-content 블록에서 내부 div의 텍스트만 추출
        inner_html = if html =~ /<div class="trix-content">\s*<div>(.*?)<\/div>\s*<\/div>/m
          $1.strip
        else
          ActionView::Base.full_sanitizer.sanitize(html).strip
        end
        inner = ActionView::Base.full_sanitizer.sanitize(inner_html)
        indent = "  " * (level - 5)
        md += "#{indent}* #{inner}\n"
      end
      # 하위 노드가 있으면 재귀
      if creative.respond_to?(:children) && creative.children.present?
        md += render_creative_tree_markdown(creative.children, level + 1)
      end
      md += "\n" if level <= 4
    end
    md
  end

  def markdown_links_to_html(text)
    return "" if text.nil?
    text.gsub(/\[([^\]]+)\]\(([^)]+)\)/) { "<a href=\"#{$2}\">#{$1}\</a>" }
  end

  def html_links_to_markdown(text)
    return "" if text.nil?
    text.gsub(/<a [^>]*href=['"]([^'"]+)['"][^>]*>(.*?)<\/a>/m) do
      inner = ActionView::Base.full_sanitizer.sanitize($2)
      "[#{inner}](#{$1})"
    end
  end
end
