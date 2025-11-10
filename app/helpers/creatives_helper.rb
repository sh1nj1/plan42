require "base64"
require "securerandom"
require "nokogiri"
require "set"

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
        origin = creative.effective_origin
        comments_count = origin.comments.size
        pointer = CommentReadPointer.find_by(user: Current.user, creative: origin)
        last_read_id = pointer&.last_read_comment_id
        unread_count = last_read_id ? origin.comments.where("id > ? and private = ?", last_read_id, false).count : comments_count
        if CommentPresenceStore.list(origin.id).include?(Current.user.id)
          unread_count = 0
        end
        classes = [ "comments-btn", "creative-action-btn" ]
        classes << "no-comments" if comments_count.zero?
        comment_icon = svg_tag(
          "comment.svg",
          class: "comment-icon"
        )
        badge_id = "comment-badge-#{origin.id}"
        stream = turbo_stream_from [ Current.user, origin, :comment_badge ]
        badge = render(
          Inbox::BadgeComponent.new(
            count: unread_count,
            badge_id: badge_id,
            show_zero: comments_count.positive?
          )
        )
        stream + button_tag(
          comment_icon + badge,
          name: "show-comments-btn",
          data: { creative_id: creative.id, can_comment: true, creative_snippet: creative.creative_snippet },
          class: classes.join(" ")
        )
      else
        "".html_safe
      end
      render_progress_value(progress_value) + comment_part + "<br />".html_safe + (creative.tags ? render_creative_tags(creative) : "".html_safe)
    end
  end

  def render_progress_value(value)
    text = number_to_percentage(value * 100, precision: 0)
    if value == 1 && !Current.user&.completion_mark.nil?
      text = Current.user.completion_mark
    end
    content_tag(
      :span,
      text,
      class: "creative-progress-#{value == 1 ? 'complete' : 'incomplete'}"
    )
  end

  def render_creative_tree(creatives, level = 1, select_mode: false, max_level: User::DEFAULT_DISPLAY_LEVEL, visited_ids: nil)
    return "".html_safe if level > max_level

    visited_ids ||= Set.new

    rows = creatives.each_with_object([]) do |creative, collection|
      next if creative.nil?
      next if visited_ids.include?(creative.id)

      current_path = visited_ids.dup
      current_path.add(creative.id)

      filtered_children = if params[:comment] == "true"
                            []
      else
                            creative.children_with_permission(Current.user)
      end
      filtered_children = filtered_children.reject { |child| current_path.include?(child.id) }
      filtered_children = filtered_children.uniq(&:id)

      expanded = expanded_from_expanded_state(creative.id, @expanded_state_map)
      filters = params.to_unsafe_h.except(:id, :controller, :action).present?

      render_children = lambda do |child_level|
        return "".html_safe if filtered_children.empty? || child_level > max_level

        content_tag(
          :div,
          id: "creative-children-#{creative.id}",
          class: "creative-children",
          style: "#{filters || expanded ? "" : "display: none;"}",
          data: {
            expanded: expanded,
            loaded: (filters || expanded),
            load_url: children_creative_path(creative, level: child_level, select_mode: select_mode ? 1 : 0)
          }
        ) do
          if filters || expanded
            render_creative_tree(
              filtered_children,
              child_level,
              select_mode: select_mode,
              max_level: max_level,
              visited_ids: current_path
            )
          else
            "".html_safe
          end
        end
      end

      skip = false
      if !skip && params[:tags].present?
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
        collection << render_children.call(level)
        next
      end

      description_html = embed_youtube_iframe(creative.effective_description(params[:tags]&.first))
      progress_html = render_creative_progress(creative, select_mode: select_mode)

      collection << (
        creative_tree_row_element(
          creative: creative,
          select_mode: select_mode,
          description_html: description_html,
          progress_html: progress_html,
          level: level,
          has_children: filtered_children.any?,
          expanded: expanded
        ) + render_children.call(level + 1)
      )
    end

    safe_join(rows)
  end

  def creative_tree_row_element(creative:, select_mode:, description_html:, progress_html:, level:, has_children:, expanded:)
    templates = [
      content_tag(:template, data: { part: "description" }) { description_html },
      content_tag(:template, data: { part: "progress" }) { progress_html },
      content_tag(:template, data: { part: "edit-icon" }) { svg_tag("edit.svg", class: "icon-edit") },
      content_tag(:template, data: { part: "edit-off-icon" }) { svg_tag("edit-off.svg", class: "icon-edit") }
    ]

    attrs = {
      "creative-id": creative.id,
      "dom-id": "creative-#{creative.id}",
      "parent-id": creative.parent_id,
      "select-mode": (select_mode ? "" : nil),
      "can-write": (creative.has_permission?(Current.user, :write) ? "" : nil),
      "level": level,
      "has-children": (has_children ? "" : nil),
      "expanded": (expanded ? "" : nil),
      "is-root": (creative.parent.nil? ? "" : nil),
      "link-url": creative_path(creative)
    }

    content_tag("creative-tree-row", safe_join(templates), attrs)
  end

  # parent_creative.expandedState[creative.id] 값 사용, parent_creative가 nil이면 controller에서 내려준 expanded_state_map[nil] 사용
  def expanded_from_expanded_state(creative_id, expanded_state_map)
    !!(expanded_state_map && expanded_state_map[creative_id.to_s])
  end

  # 트리 구조를 마크다운으로 변환하는 헬퍼
  # creatives: 트리 배열, level: 현재 깊이(1부터 시작)
  def render_creative_tree_markdown(creatives, level = 1, with_progress = false)
    return "" if creatives.blank?
    md = ""
    creatives.each do |creative|
      desc = creative.effective_description(nil, false).to_html
      # Append progress as a percentage if available (progress is 0.0..1.0)
      if with_progress && creative.respond_to?(:progress) && !creative.progress.nil?
        pct = (creative.progress.to_f * 100).round
        desc = "#{desc} (#{pct}%)"
      end
      raw_html = desc.gsub(/<!--.*?-->/m, "").strip
      markdown_content = html_links_to_markdown(raw_html)
      cleaned_markdown = markdown_content.strip
      rendered_table_block = false

      # Extract table content from within divs if present
      table_match = cleaned_markdown.match(/^<div[^>]*>\s*<div[^>]*>\s*(\|.*?\|(?:\n\|.*?\|)*)\s*<\/div>\s*<\/div>$/m)
      if level <= 4 && table_match
        table_content = table_match[1].strip
        if markdown_table_block?(table_content)
          md += "#{table_content}\n\n"
          rendered_table_block = true
        end
      elsif level <= 4 && markdown_table_block?(cleaned_markdown)
        md += "#{cleaned_markdown}\n\n"
        rendered_table_block = true
      elsif level <= 4
        md += "#{'#' * level} #{ActionView::Base.full_sanitizer.sanitize(markdown_content).strip}\n\n"
      else
        # trix-content 블록에서 내부 div의 텍스트만 추출
        inner_html = begin
          fragment = Nokogiri::HTML.fragment(raw_html)
          wrapper = fragment.at_css("div.trix-content")
          if wrapper
            wrapper.inner_html.strip
          else
            ActionView::Base.full_sanitizer.sanitize(markdown_content).strip
          end
        end
        inner = ActionView::Base.full_sanitizer.sanitize(inner_html)
        indent = "  " * (level - 5)
        md += "#{indent}* #{inner}\n"
      end
      # 하위 노드가 있으면 재귀
      if creative.respond_to?(:children) && creative.children.present?
        md += render_creative_tree_markdown(creative.children, level + 1, with_progress)
      end
      md += "\n" if level <= 4 && !rendered_table_block
    end
    md
  end

  def markdown_links_to_html(text, image_refs = {})
    return "" if text.nil?
    html = text.dup

    html.gsub!(/^\s*\[([^\]]+)\]:\s*<\s*(data:image\/[^>]+)\s*>\s*$/) do
      image_refs[$1] = $2.strip
      ""
    end

    html.gsub!(/(?<!\\)!\[([^\]]*)\]\[([^\]]+)\]/) do
      if (data_url = image_refs[$2])
        convert_data_image_to_attachment(data_url, $1)
      else
        "![#{$1}][#{$2}]"
      end
    end

    html.gsub!(/(?<!\\)!\[([^\]]*)\]\((data:image\/[^)]+)\)/) do
      convert_data_image_to_attachment($2, $1)
    end
    html.gsub!(/(?<!\\)\[([^\]]+)\]\(([^)]+)\)/) do
      "<a href=\"#{$2}\">#{$1}</a>"
    end
    html.gsub!(/(?<!\\)(\*\*|__)(.+?)\1/m) do
      "<strong>#{$2}</strong>"
    end
    html.gsub!(/\\([\\*_\[\]()!#~+\-])/, '\\1')
    html.gsub!(/\\\\/, "\\")
    html.strip!
    html
  end

  def html_links_to_markdown(text)
    return "" if text.nil?
    markdown = text.dup
    placeholders = {}
    index = 0
    markdown.gsub!(%r{<table\b[^>]*>.*?</table>}im) do |match|
      token = "__TABLE#{index}__"; index += 1
      placeholders[token] = html_table_to_markdown(match)
      token
    end
    markdown.gsub!(%r{<action-text-attachment ([^>]+)>(?:</action-text-attachment>)?}) do |match|
      attrs = Hash[$1.scan(/(\S+?)="([^"]*)"/)]
      sgid = attrs["sgid"]
      caption = attrs["caption"] || ""
      if (blob = GlobalID::Locator.locate_signed(sgid, for: "attachable"))
        data = Base64.strict_encode64(blob.download)
        token = "__IMG#{index}__"; index += 1
        placeholders[token] = "![#{caption}](data:#{blob.content_type};base64,#{data})"
        token
      else
        ""
      end
    end
    markdown.gsub!(/<img [^>]*src=['"](data:[^'"]+)['"][^>]*alt=['"]([^'"]*)['"][^>]*>/) do
      token = "__IMG#{index}__"; index += 1
      placeholders[token] = "![#{$2}](#{$1})"
      token
    end
    markdown.gsub!(/<img [^>]*alt=['"]([^'"]*)['"][^>]*src=['"](data:[^'"]+)['"][^>]*>/) do
      token = "__IMG#{index}__"; index += 1
      placeholders[token] = "![#{$1}](#{$2})"
      token
    end
    markdown.gsub!(/<a [^>]*href=['"]([^'"]+)['"][^>]*>(.*?)<\/a>/m) do
      inner = ActionView::Base.full_sanitizer.sanitize($2)
      token = "__LINK#{index}__"; index += 1
      placeholders[token] = "[#{inner}](#{$1})"
      token
    end
    markdown.gsub!(/<(strong|b)(?:\s+[^>]*)?>(.*?)<\/\1>/im) do
      token = "__BOLD#{index}__"; index += 1
      placeholders[token] = "**#{$2.strip}**"
      token
    end
    markdown.gsub!(/([\\*\[\]()!#~+\-])/) { "\\#{$1}" }
    placeholders.each { |k, v| markdown.gsub!(k, v) }
    markdown
  end

  private

  def markdown_table_block?(text)
    lines = text.to_s.strip.split("\n")
    return false if lines.length < 2

    header_line = lines[0]
    alignment_line = lines[1]
    return false unless header_line.match?(/\A\|.*\|\z/)
    return false unless alignment_line.match?(/\A\|[ \-:\|]+\|\z/)

    true
  end

  def convert_data_image_to_attachment(data_url, alt)
    if data_url =~ %r{\Adata:(image/[\w.+-]+);base64,(.+)\z}
      content_type = Regexp.last_match(1)
      data = Base64.decode64(Regexp.last_match(2))
      ext = Mime::Type.lookup(content_type).symbol.to_s
      filename = "import-#{SecureRandom.hex}.#{ext}"
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: filename, content_type: content_type)
      ActionText::Attachment.from_attachable(blob, caption: alt).to_html
    else
      "<img src=\"#{data_url}\" alt=\"#{alt}\" />"
    end
  end

  def html_table_to_markdown(table_html)
    fragment = Nokogiri::HTML::DocumentFragment.parse(table_html)
    table = fragment.at_css("table")
    return "" unless table

    header_row = table.at_css("thead tr") || table.css("tr").first
    return "" unless header_row

    header_cells = header_row.css("th,td")
    headers = header_cells.map { |cell| escape_markdown_table_cell(html_links_to_markdown(cell.inner_html).strip) }

    alignments = header_cells.map { |cell| alignment_from_html_cell(cell) }

    body_rows = table.css("tbody tr")
    if body_rows.empty?
      all_rows = table.css("tr")
      body_rows = all_rows.drop(1)
    end

    body_lines = body_rows.map do |row|
      cells = row.css("th,td").map { |cell| escape_markdown_table_cell(html_links_to_markdown(cell.inner_html).strip) }
      normalized = normalize_row_cells(cells, headers.length)
      "| #{normalized.join(' | ')} |"
    end

    alignment_cells = normalize_row_cells(alignments, headers.length).map { |align| alignment_to_markdown(align) }
    header_line = "| #{headers.map(&:strip).join(' | ')} |"
    alignment_line = "| #{alignment_cells.join(' | ')} |"

    ([ header_line, alignment_line ] + body_lines).join("\n")
  end

  def escape_markdown_table_cell(text)
    text.to_s.gsub(/(?<!\\)\|/, '\\|')
  end

  def alignment_from_html_cell(cell)
    style = cell["style"].to_s
    align = cell["align"].to_s
    case
    when style =~ /text-align\s*:\s*center/i || align =~ /center/i
      :center
    when style =~ /text-align\s*:\s*right/i || align =~ /right/i
      :right
    when style =~ /text-align\s*:\s*left/i || align =~ /left/i
      :left
    else
      nil
    end
  end

  def alignment_to_markdown(alignment)
    case alignment
    when :center
      ":---:"
    when :right
      "---:"
    when :left
      ":---"
    else
      "---"
    end
  end

  def normalize_row_cells(cells, expected_length)
    values = cells.dup
    values = values.first(expected_length)
    values.fill("", values.length...expected_length)
    values
  end
end
