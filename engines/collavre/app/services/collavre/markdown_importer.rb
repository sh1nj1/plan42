module Collavre
  class MarkdownImporter
    # Matches horizontal rules: ---, ***, ___ (with optional spaces)
    HORIZONTAL_RULE_REGEX = /^\s*([-*_])\s*\1\s*\1[\s\1]*$/

    def self.import(content, parent:, user:, create_root: false)
      lines = content.to_s.lines
      image_refs = {}
      lines.reject! do |ln|
        if ln =~ /^\s*\[([^\]]+)\]:\s*<\s*(data:image\/[^>]+)\s*>\s*$/
          image_refs[$1] = $2.strip
          true
        else
          false
        end
      end
      created = []
      root = parent
      i = 0
      if create_root
        while i < lines.size && lines[i].strip.empty?
          i += 1
        end
        if i < lines.size && lines[i] !~ /^\s*#/ && lines[i] !~ /^\s*[-*+]/
          page_title = lines[i].strip
          root = Creative.create(user: user, parent: parent, description: page_title)
          created << root
          i += 1
        end
      end
      stack = [ [ 0, root ] ]
      while i < lines.size
        line = lines[i]

        # Skip horizontal rules (---, ***, ___)
        if line =~ HORIZONTAL_RULE_REGEX
          i += 1
          next
        end

        # Handle fenced code blocks (``` or ~~~)
        if (fence_match = line.match(/^(\s*)(`{3,}|~{3,})(.*)$/))
          fence_indent = fence_match[1]
          fence_marker = fence_match[2]
          fence_char = fence_marker[0]
          fence_length = fence_marker.length
          fence_info = fence_match[3].strip # language info (e.g., "ruby", "javascript")

          # Collect all lines until closing fence
          code_lines = []
          i += 1
          while i < lines.size
            close_line = lines[i]
            # Check for closing fence (same char, at least same length)
            if (close_match = close_line.match(/^\s*(`{3,}|~{3+})\s*$/))
              close_marker = close_match[1]
              if close_marker[0] == fence_char && close_marker.length >= fence_length
                i += 1
                break
              end
            end
            code_lines << close_line
            i += 1
          end

          # Build code block HTML
          code_content = code_lines.join
          code_html = build_code_block_html(code_content, fence_info)

          new_parent = stack.any? ? stack.last[1] : root
          c = Creative.create(user: user, parent: new_parent, description: code_html)
          created << c
          next
        end

        if (table_data = parse_markdown_table(lines, i))
          table_html = build_table_html(table_data, image_refs)
          new_parent = stack.any? ? stack.last[1] : root
          c = Creative.create(user: user, parent: new_parent, description: table_html)
          created << c
          i = table_data[:next_index]
        elsif line =~ /^(#+)\s+(.*)$/
          level = $1.length
          desc = ApplicationController.helpers.markdown_links_to_html($2.strip, image_refs)
          stack.pop while stack.any? && stack.last[0] >= level
          new_parent = stack.any? ? stack.last[1] : root
          c = Creative.create(user: user, parent: new_parent, description: desc)
          created << c
          stack << [ level, c ]
          i += 1
        elsif line =~ /^([ \t]*)([-*+])\s+(.*)$/
          indent = $1.length
          desc = ApplicationController.helpers.markdown_links_to_html($3.strip, image_refs)
          bullet_level = 10 + indent / 2
          stack.pop while stack.any? && stack.last[0] >= bullet_level
          new_parent = stack.any? ? stack.last[1] : root
          c = Creative.create(user: user, parent: new_parent, description: desc)
          created << c
          stack << [ bullet_level, c ]
          i += 1
        elsif !line.strip.empty?
          desc = ApplicationController.helpers.markdown_links_to_html(line.strip, image_refs)
          new_parent = stack.any? ? stack.last[1] : root
          c = Creative.create(user: user, parent: new_parent, description: desc)
          created << c
          i += 1
        else
          i += 1
        end
      end
      created
    end

    def self.build_code_block_html(code_content, language = nil)
      escaped_content = ERB::Util.html_escape(code_content)
      lang_class = language.present? ? " class=\"language-#{ERB::Util.html_escape(language)}\"" : ""
      "<pre><code#{lang_class}>#{escaped_content}</code></pre>"
    end

    def self.parse_markdown_table(lines, index)
      return nil if index >= lines.length
      header_line = lines[index]
      return nil unless table_row?(header_line)

      align_index = index + 1
      return nil if align_index >= lines.length
      alignment_line = lines[align_index]
      return nil unless alignment_row?(alignment_line)

      header_cells = split_markdown_table_row(header_line)
      alignments = parse_alignment_row(alignment_line, header_cells.length)

      rows = []
      data_index = align_index + 1
      while data_index < lines.length && table_row?(lines[data_index])
        rows << split_markdown_table_row(lines[data_index])
        data_index += 1
      end

      {
        header: header_cells,
        alignments: alignments,
        rows: rows,
        next_index: data_index
      }
    end

    def self.table_row?(line)
      return false if line.nil?
      stripped = line.strip
      return false if stripped.empty?
      stripped.include?("|") && split_markdown_table_row(line).any?
    end

    def self.alignment_row?(line)
      return false unless table_row?(line)
      split_markdown_table_row(line).all? do |cell|
        cell.strip =~ /^:?-{3,}:?$/
      end
    end

    def self.split_markdown_table_row(line)
      body = line.strip
      body = body.sub(/^\|/, "").sub(/\|\s*$/, "")
      return [] if body.strip.empty?
      body.split(/(?<!\\)\|/).map { |cell| cell.gsub(/\\\|/, "|").strip }
    end

    def self.parse_alignment_row(line, expected_count)
      cells = split_markdown_table_row(line)
      cells = cells.first(expected_count)
      cells.fill("", cells.length...expected_count)
      cells.map do |cell|
        trimmed = cell.strip
        left = trimmed.start_with?(":")
        right = trimmed.end_with?(":")
        if left && right
          :center
        elsif right
          :right
        elsif left
          :left
        else
          nil
        end
      end
    end

    def self.build_table_html(table_data, image_refs)
      helper = ApplicationController.helpers
      header_cells = table_data[:header]
      alignments = table_data[:alignments]
      rows = table_data[:rows]

      header_html = header_cells.map { |cell| helper.markdown_links_to_html(cell, image_refs) }
      max_row_length = rows.map(&:length).max || 0
      column_count = [ header_html.length, max_row_length ].max

      row_html = rows.map do |row|
        normalized = row.first(column_count)
        normalized.fill("", normalized.length...column_count)
        normalized.map { |cell| helper.markdown_links_to_html(cell, image_refs) }
      end

      column_count = [ column_count, alignments.length ].max
      alignments = alignments.first(column_count)
      alignments.fill(nil, alignments.length...column_count)

      build_html_table(header_html, row_html, alignments)
    end

    def self.build_html_table(header_html, rows_html, alignments)
      table = +"<table>\n"
      table << "  <thead>\n"
      table << "    <tr>"
      header_html.each_with_index do |cell, idx|
        table << table_cell_tag("th", cell, alignments[idx])
      end
      table << "</tr>\n"
      table << "  </thead>\n"
      unless rows_html.empty?
        table << "  <tbody>\n"
        rows_html.each do |row|
          table << "    <tr>"
          row.each_with_index do |cell, idx|
            table << table_cell_tag("td", cell, alignments[idx])
          end
          table << "</tr>\n"
        end
        table << "  </tbody>\n"
      end
      table << "</table>"
      table
    end

    def self.table_cell_tag(tag_name, content, alignment)
      align_attr = alignment ? " style=\"text-align: #{alignment};\"" : ""
      "<#{tag_name}#{align_attr}>#{content}</#{tag_name}>"
    end
  end
end
