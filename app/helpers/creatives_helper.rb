module CreativesHelper
  # Shared toggle button symbol helper
  def toggle_button_symbol(expanded: false)
    expanded ? "\u25BC" : "\u25B6" # ▼ or ▶
  end

  def render_tags(labels, class_name = nil)
    return "" if labels&.empty? or labels.nil?

    index = 0
    safe_join(labels.map do |label|
      suffix = " 🗓#{label.target_date}" if label.type == "Plan"
      index += 1
      content_tag(:span, class: "tag") do
        (index == 1 ? "" : " ").html_safe +
        link_to("##{label.name}", creatives_path(tags: [ label.id ]), class: class_name ? class_name: "", title: label.name) + suffix
      end
    end)
  end

  def render_creative_progress(creative)
    content_tag(:div, class: "creative-row-end") do
      content_tag(:span, number_to_percentage(creative.progress * 100, precision: 0), class: "creative-progress-#{creative.progress == 1 ? "complete" : "incomplete"}") +
        button_tag("(#{creative.comments.size})", name: "show-comments-btn",
                   "data-creative-id": creative.id)
    end
  end

  def render_creative_tree(creatives, level = 1, select_mode: false)
    safe_join(
      creatives.map do |creative|
        drag_attrs = {
          draggable: true,
          id: "creative-#{creative.id}",
          ondragstart: "handleDragStart(event)",
          ondragover: "handleDragOver(event)",
          ondrop: "handleDrop(event)"
        }
        filtered_children = creative.children_with_permission(Current.user)
        render_next_block = ->(level) {
          (filtered_children.any? ? content_tag(:div, id: "creative-children-#{creative.id}", class: "creative-children") {
            render_creative_tree(filtered_children, level, select_mode: select_mode)
          }: "".html_safe)
        }
        render_row_content = ->(wrapper) {
          content_tag(:div, class: "creative-row-start") do
            content_tag(:div, class: "creative-row-actions") do
              content_tag(:div, ((level <= 3 and filtered_children.any?) ? toggle_button_symbol(expanded: true) : ""),
                          class: "before-link creative-toggle-btn",
                          data: { creative_id: creative.id }) +
                (
                  select_mode ?
                    check_box_tag("selected_creative_ids[]", creative.id, false, class: "select-creative-checkbox") :
                    link_to("+", new_creative_path(parent_id: creative.id),
                      class: "add-creative-btn",
                      style: "#{' visibility: hidden;' unless creative.has_permission?(Current.user, :write)}",
                      title: I18n.t("creatives.help.add_child_creative")
                    )
                )
            end +
            wrapper.call {
              link_to(creative.effective_description(params[:tags]&.first), creative, class: "unstyled-link")
            }
          end + render_creative_progress(creative)
        }

        skip = false
        if params[:tags].present?
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
          content_tag(:div, class: "creative-tree", **drag_attrs) do
            content_tag(:div, class: "creative-row") do
              render_row_content.call(renderer)
            end
          end + render_next_block.call(level + 1)
        end
      end
    )
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
