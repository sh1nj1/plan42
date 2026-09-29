module CollavreNotion
  class NotionCreativeExporter
    include Collavre::CreativesHelper

    def initialize(creative, with_progress: false)
      @creative = creative
      @with_progress = with_progress
    end

    # Descendant Creatives are exported by NotionTreeSync as child pages.
    def export_blocks
      html = export_html
      blocks = html.split(/(<table\b[^>]*>.*?<\/table>)/mi).flat_map do |part|
        contains_table?(part) ? convert_table_to_blocks(part) : paragraph_blocks(extract_text_content(part))
      end
      blocks.concat(paragraph_blocks("(#{(@creative.progress.to_f * 100).round}%)")) if @with_progress
      blocks + convert_rich_content_to_blocks(html)
    end

    private

    def export_html
      fragment = Nokogiri::HTML5.fragment(@creative.effective_description.to_s)
      fragment.xpath(".//comment()").remove
      fragment.to_html.strip
    end

    def paragraph_blocks(text)
      text.scan(/.{1,2000}/m).map { |part| create_paragraph_block(part) }
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
          blocks.concat(table_data.flat_map { |row| split_table_row(row) }.each_slice(100).map { |rows| create_table_block(rows) })
        end
      else
        # Try markdown table format
        markdown_table = extract_markdown_table(html)
        if markdown_table
          table_data = parse_markdown_table(markdown_table)
          if table_data.any?
            blocks.concat(table_data.flat_map { |row| split_table_row(row) }.each_slice(100).map { |rows| create_table_block(rows) })
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

        cells = line.split("|", -1)[1...-1].map(&:strip)
        next if cells.empty?

        cell_contents = cells.map { |cell| create_table_cell_content(cell.strip) }
        rows << cell_contents
      end

      rows
    end

    def extract_markdown_table(html)
      # Look for markdown table patterns in the HTML
      html.lines.select { |line| line.strip.start_with?("|") && line.strip.end_with?("|") }.join
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
          blocks.concat(paragraph_blocks("📷 #{caption.presence || I18n.t("collavre_notion.export.image_attachment")}"))
        end
      end

      # Extract data URLs for images
      html.scan(/<img [^>]*src=['"](data:[^'"]+)['"][^>]*alt=['"]([^'"]*)['"][^>]*>/) do |data_url, alt_text|
        blocks.concat(paragraph_blocks("📷 #{alt_text.presence || I18n.t("collavre_notion.export.image")}"))
      end

      blocks
    end

    def extract_text_content(html)
      fragment = Nokogiri::HTML.fragment(html)
      fragment.css("br").each { |node| node.replace("\n") }
      fragment.css("p, div, li, h1, h2, h3, h4, h5, h6").each { |node| node.add_next_sibling("\n") }
      Collavre::HtmlText.plain(fragment.to_html).strip
    end

    def create_paragraph_block(text)
      {
        object: "block",
        type: "paragraph",
        paragraph: {
          rich_text: [ { type: "text", text: { content: text } } ]
        }
      }
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

    # Continue oversized cells on subsequent rows without losing column alignment.
    def split_table_row(row)
      count = [ (row.map(&:length).max.to_f / 100).ceil, 1 ].max
      Array.new(count) do |index|
        row.map { |cell| cell.slice(index * 100, 100) || [] }
      end
    end

    def create_table_cell_content(text)
      text.to_s.scan(/.{1,2000}/m).map { |part| { type: "text", text: { content: part } } }
    end
  end
end
