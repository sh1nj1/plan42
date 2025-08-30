require "base64"
require "securerandom"

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
        unread_count = last_read_id ? origin.comments.where("id > ?", last_read_id).count : comments_count
        if CommentPresenceStore.list(origin.id).include?(Current.user.id)
          unread_count = 0
        end
        classes = [ "comments-btn", "creative-action-btn" ]
        classes << "no-comments" if comments_count.zero?
        comment_icon = svg_tag(
          "comment.svg",
          class: "comment-icon"
        )
        badge = render(
          Inbox::BadgeComponent.new(
            count: unread_count,
            badge_id: "comment-badge-#{creative.id}",
            show_zero: comments_count.positive?
          )
        )
        button_tag(
          comment_icon + badge,
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
        md += "#{'#' * level} #{ActionView::Base.full_sanitizer.sanitize(html).strip}\n\n"
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
    html.gsub!(/(?<!\\)(\*\*|__)(.+?)\1/) do
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
    markdown.gsub!(/<(strong|b)>(.*?)<\/\1>/m) do
      token = "__BOLD#{index}__"; index += 1
      placeholders[token] = "**#{$2.strip}**"
      token
    end
    markdown.gsub!(/([\\*\[\]()!#~+\-])/) { "\\#{$1}" }
    placeholders.each { |k, v| markdown.gsub!(k, v) }
    markdown
  end

  private

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
end
