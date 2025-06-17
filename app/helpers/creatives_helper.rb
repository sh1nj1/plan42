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
        btn_text = comments_count.zero? ? "\u{1F4AC}" : "(#{comments_count})"
        classes = [ "comments-btn" ]
        classes << "no-comments" if comments_count.zero?
        button_tag(
          btn_text,
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

  def filter_creatives(creatives)
    creatives.flat_map do |creative|
      children = creative.children_with_permission(Current.user)

      skip = false
      if params[:tags].present?
        tag_ids = Array(params[:tags]).map(&:to_s)
        creative_label_ids = creative.tags.pluck(:label_id).map(&:to_s)
        skip = (creative_label_ids & tag_ids).empty?
      end
      if !skip && params[:min_progress].present?
        min_progress = params[:min_progress].to_f
        skip = creative.progress < min_progress
      end
      if !skip && params[:max_progress].present?
        max_progress = params[:max_progress].to_f
        skip = creative.progress > max_progress
      end

      if skip
        filter_creatives(children)
      else
        [ creative ]
      end
    end
  end

  def render_creative_tree(creatives, level = 1, select_mode: false)
    safe_join(
      filter_creatives(creatives).map do |creative|
        render CreativeComponent.new(
          creative: creative,
          level: level,
          expanded_state_map: @expanded_state_map,
          select_mode: select_mode
        )
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
    sanitizer = ActionView::Base.full_sanitizer
    creatives.each do |creative|
      desc = creative.effective_description(nil, false)
      if level <= 4
        md += "#{'#' * level} #{desc.to_plain_text}\n\n"
      else
        html = desc.to_s.gsub(/<!--.*?-->/m, "").strip
        # trix-content 블록에서 내부 div의 텍스트만 추출
        if html =~ /<div class="trix-content">\s*<div>(.*?)<\/div>\s*<\/div>/m
          inner = $1.strip
          md += "<li>#{inner}</li>\n\n"
        else
          md += "<li>#{ActionView::Base.full_sanitizer.sanitize(html)}</li>\n\n"
        end
      end
      # 하위 노드가 있으면 재귀
      md += "<ul>\n" if level > 4
      if creative.respond_to?(:children) && creative.children.present?
        md += render_creative_tree_markdown(creative.children, level + 1)
      end
      md += "</ul>\n\n" if level > 4
    end
    md
  end
end
