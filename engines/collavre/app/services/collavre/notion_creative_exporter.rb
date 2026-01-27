module Collavre
  class NotionCreativeExporter
    include CreativesHelper

    def initialize(creative, with_progress: false)
      @creative = creative
      @with_progress = with_progress
    end

    def export_blocks
      convert_creative_to_blocks(@creative, level: 1)
    end

    def export_tree_blocks(creatives, level = 1, bullet_depth = 0)
      return [] if creatives.blank?

      blocks = []
      creatives.each do |creative|
        # Convert the creative to blocks
        creative_blocks = convert_creative_to_blocks(creative, level: level)

        # Handle children based on the level
        if creative.respond_to?(:children) && creative.children.present?
          if level > 3
            # For bullet points (level > 3), limit nesting depth to 2 levels max
            text_content = extract_text_content(creative.effective_description(nil, true).gsub(/<!--.*?-->/m, "").strip)

            if bullet_depth < 2
              # Can still nest deeper
              children_blocks = export_tree_blocks(creative.children, level + 1, bullet_depth + 1)
              bullet_block = create_bulleted_list_item_block(text_content, children_blocks)
              blocks << bullet_block
            else
              # Max depth reached, flatten remaining levels
              bullet_block = create_bulleted_list_item_block(text_content)
              blocks << bullet_block
              # Add children as flat bullet points at same level
              blocks.concat(export_tree_blocks(creative.children, level, bullet_depth))
            end
          else
            # For headings (level <= 3), add heading then children as separate blocks
            blocks.concat(creative_blocks)
            blocks.concat(export_tree_blocks(creative.children, level + 1, 0))
          end
        else
          # No children, just add the blocks
          blocks.concat(creative_blocks)
        end
      end

      blocks
    end

    private

    def convert_creative_to_blocks(creative, level: 1)
      blocks = []
      description_content = creative.effective_description(nil, true)
      desc = description_content.present? ? description_content.to_s : ""

      # Add progress if requested and available
      if @with_progress && creative.respond_to?(:progress) && !creative.progress.nil?
        pct = (creative.progress.to_f * 100).round
        desc = "#{desc} (#{pct}%)"
      end

      # Clean HTML and prepare content
      raw_html = desc.gsub(/<!--.*?-->/m, "").strip

      # Handle different content types
      if level <= 3 && contains_table?(raw_html)
        blocks.concat(convert_table_to_blocks(raw_html))
      elsif level <= 3
        # Use as heading
        text_content = extract_text_content(raw_html)
        if text_content.present?
          blocks << create_heading_block(text_content, level)
        end
      else
        # Use as bulleted list item for deeper levels
        text_content = extract_text_content(raw_html)
        if text_content.present?
          blocks << create_bulleted_list_item_block(text_content)
        end
      end

      # Handle rich content like images and links within the HTML
      blocks.concat(convert_rich_content_to_blocks(raw_html))

      blocks
    end

    def contains_table?(html)
      html.match?(%r{<table\b[^>]*>.*?</table>}im) ||
        html.match?(/^\s*\|.*?\|(?:\s*\n\s*\|.*?\|)*\s*$/m)
    end

    def convert_table_to_blocks(html)
      blocks = []

      # Extract table content
      table_match = html.match(%r{<table\b[^>]*>(.*?)</table>}im)
      if table_match
        table_html = table_match[1]
        table_data = parse_html_table(table_html)
        if table_data.any?
          blocks << create_table_block(table_data)
        end
      else
        # Try markdown table format
        markdown_table = extract_markdown_table(html)
        if markdown_table
          table_data = parse_markdown_table(markdown_table)
          if table_data.any?
            blocks << create_table_block(table_data)
          end
        end
      end

      blocks
    end

    def parse_html_table(table_html)
      fragment = Nokogiri::HTML::DocumentFragment.parse("<table>#{table_html}</table>")
      table = fragment.at_css("table")
      return [] unless table

      rows = []
      table.css("tr").each do |row|
        cells = row.css("th,td").map do |cell|
          text = extract_text_content(cell.inner_html)
          create_table_cell_content(text)
        end
        rows << cells if cells.any?
      end

      rows
    end

    def parse_markdown_table(table_text)
      lines = table_text.strip.split("\n").map(&:strip)
      return [] if lines.length < 2

      rows = []
      lines.each_with_index do |line, index|
        next if index == 1 # Skip alignment row

        cells = line.split("|").map(&:strip).reject(&:empty?)
        next if cells.empty?

        cell_contents = cells.map { |cell| create_table_cell_content(cell.strip) }
        rows << cell_contents
      end

      rows
    end

    def extract_markdown_table(html)
      # Look for markdown table patterns in the HTML
      html.match(/(\|.*?\|(?:\s*\n\s*\|.*?\|)*)/m)&.captures&.first
    end

    def convert_rich_content_to_blocks(html)
      blocks = []

      # Extract images
      html.scan(%r{<action-text-attachment ([^>]+)>(?:</action-text-attachment>)?}) do |match|
        attrs = Hash[match[0].scan(/(\S+?)="([^"]*)"/)]
        sgid = attrs["sgid"]
        caption = attrs["caption"] || ""

        if (blob = GlobalID::Locator.locate_signed(sgid, for: "attachable"))
          # For now, we'll create a paragraph with the image description
          # In a full implementation, you'd upload to Notion's file storage
          blocks << create_paragraph_block("📷 #{caption.presence || 'Image attachment'}")
        end
      end

      # Extract data URLs for images
      html.scan(/<img [^>]*src=['"](data:[^'"]+)['"][^>]*alt=['"]([^'"]*)['"][^>]*>/) do |data_url, alt_text|
        blocks << create_paragraph_block("📷 #{alt_text.presence || 'Image'}")
      end

      blocks
    end

    def extract_text_content(html)
      # Remove HTML tags and get plain text
      ActionView::Base.full_sanitizer.sanitize(html).strip
    end

    def create_heading_block(text, level)
      # Notion supports heading_1, heading_2, heading_3
      heading_type = case level
      when 1 then "heading_1"
      when 2 then "heading_2"
      else "heading_3"
      end

      heading_key = heading_type.to_sym

      {
        object: "block",
        type: heading_type,
        heading_key => {
          rich_text: [ create_rich_text(text) ]
        }
      }
    end

    def create_paragraph_block(text)
      {
        object: "block",
        type: "paragraph",
        paragraph: {
          rich_text: [ create_rich_text(text) ]
        }
      }
    end

    def create_bulleted_list_item_block(text, children_blocks = [])
      block = {
        object: "block",
        type: "bulleted_list_item",
        bulleted_list_item: {
          rich_text: [ create_rich_text(text) ]
        }
      }

      # Add nested children if present
      if children_blocks.any?
        block[:bulleted_list_item][:children] = children_blocks
      end

      block
    end

    def create_table_block(table_data)
      return nil if table_data.empty?

      # Notion tables need consistent column count
      max_columns = table_data.map(&:length).max
      normalized_rows = table_data.map do |row|
        row + Array.new([ max_columns - row.length, 0 ].max) { create_table_cell_content("") }
      end

      {
        object: "block",
        type: "table",
        table: {
          table_width: max_columns,
          has_column_header: true,
          has_row_header: false,
          children: normalized_rows.map do |row_data|
            {
              object: "block",
              type: "table_row",
              table_row: {
                cells: row_data
              }
            }
          end
        }
      }
    end

    def create_table_cell_content(text)
      [ create_rich_text(text.to_s) ]
    end

    def create_rich_text(text)
      # Notion has a 2000 character limit per text block
      content = text.to_s.strip
      if content.length > 1990  # Be conservative to account for any extra characters
        original_length = content.length
        content = content[0..1986] + "..."  # 1987 + 3 = 1990 chars
        Rails.logger.warn("NotionCreativeExporter: Truncated content from #{original_length} to #{content.length} characters")
      end

      {
        type: "text",
        text: {
          content: content
        },
        annotations: {
          bold: false,
          italic: false,
          strikethrough: false,
          underline: false,
          code: false,
          color: "default"
        }
      }
    end
  end
end
