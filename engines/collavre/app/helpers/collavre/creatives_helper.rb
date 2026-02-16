module Collavre
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
          link_to("##{strip_tags(label.name)}", collavre.creatives_path(tags: [label.id]), class: class_name ? class_name: "", title: strip_tags(label.name)) + suffix
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
        creative.filtered_progress || creative.progress_for_tags(tag_ids) || 0
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
          if Current.user && CommentPresenceStore.list(origin.id).include?(Current.user.id)
            unread_count = 0
          end
          classes = ["comments-btn", "creative-action-btn"]
          classes << "no-comments" if comments_count.zero?
          comment_icon = svg_tag(
            "comment.svg",
            class: "comment-icon"
          )
          badge_id = "comment-badge-#{origin.id}"
          stream = turbo_stream_from [Current.user, origin, :comment_badge]
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

    def expanded_from_expanded_state(creative_id, expanded_state_map)
      !!(expanded_state_map && expanded_state_map[creative_id.to_s])
    end

    def render_creative_tree_markdown(creatives, level = 1, with_progress = false, max_depth: nil)
      return "" if creatives.blank?
      md = ""
      creatives.each do |creative|
        desc = creative.effective_description(nil, true)
        if with_progress && creative.respond_to?(:progress) && !creative.progress.nil?
          pct = (creative.progress.to_f * 100).round
          desc = "#{desc} (#{pct}%)"
        end
        raw_html = desc.gsub(/<!--.*?-->/m, "").strip
        markdown_content = MarkdownConverter.html_to_markdown(raw_html)
        cleaned_markdown = markdown_content.strip
        rendered_table_block = false

        table_match = cleaned_markdown.match(/^<div[^>]*>\s*<div[^>]*>\s*(\|.*?\|(?:\n\|.*?\|)*)\s*<\/div>\s*<\/div>$/m)
        if level <= 4 && table_match
          table_content = table_match[1].strip
          if MarkdownConverter.table_block?(table_content)
            md += "#{table_content}\n\n"
            rendered_table_block = true
          end
        elsif level <= 4 && MarkdownConverter.table_block?(cleaned_markdown)
          md += "#{cleaned_markdown}\n\n"
          rendered_table_block = true
        elsif level <= 4
          md += "#{'#' * level} #{ActionView::Base.full_sanitizer.sanitize(markdown_content).strip}\n\n"
        else
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
        children = creative.linked_children
        if children.present? && (max_depth.nil? || level < max_depth)
          md += render_creative_tree_markdown(children, level + 1, with_progress, max_depth: max_depth)
        end
        md += "\n" if level <= 4 && !rendered_table_block
      end
      md
    end

    # Delegate to MarkdownConverter for backward compatibility.
    # These methods are used in views and by MarkdownImporter via ApplicationController.helpers.
    def markdown_links_to_html(text, image_refs = {})
      MarkdownConverter.markdown_to_html(text, image_refs)
    end

    def html_links_to_markdown(text)
      MarkdownConverter.html_to_markdown(text)
    end
  end
end
