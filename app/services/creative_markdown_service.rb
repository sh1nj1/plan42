class CreativeMarkdownService
  class << self
    def import(file:, parent: nil, user:)
      content = file.read.force_encoding("UTF-8")
      lines = content.lines
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
      i = 0
      while i < lines.size && lines[i].strip.empty?
        i += 1
      end
      root_creative = nil
      if i < lines.size && lines[i] !~ /^\s*#/ && lines[i] !~ /^\s*[-*+]/
        page_title = lines[i].strip
        root_creative = Creative.create(user: user, parent: parent, description: page_title)
        created << root_creative
        i += 1
      end
      root_creative ||= parent
      stack = [ [ 0, root_creative ] ]
      helpers = ApplicationController.helpers
      while i < lines.size
        line = lines[i]
        if (table_result = markdown_table_to_html(lines, i, image_refs, helpers))
          html, i = table_result
          new_parent = stack.any? ? stack.last[1] : root_creative
          c = Creative.create(user: user, parent: new_parent, description: html)
          created << c
        elsif line =~ /^(#+)\s+(.*)$/
          level = $1.length
          desc = helpers.markdown_links_to_html($2.strip, image_refs)
          stack.pop while stack.any? && stack.last[0] >= level
          new_parent = stack.any? ? stack.last[1] : root_creative
          c = Creative.create(user: user, parent: new_parent, description: desc)
          created << c
          stack << [ level, c ]
          i += 1
        elsif line =~ /^([ \t]*)([-*+])\s+(.*)$/
          indent = $1.length
          desc = helpers.markdown_links_to_html($3.strip, image_refs)
          bullet_level = 10 + indent / 2
          stack.pop while stack.any? && stack.last[0] >= bullet_level
          new_parent = stack.any? ? stack.last[1] : root_creative
          c = Creative.create(user: user, parent: new_parent, description: desc)
          created << c
          stack << [ bullet_level, c ]
          i += 1
        elsif !line.strip.empty?
          desc = helpers.markdown_links_to_html(line.strip, image_refs)
          new_parent = stack.any? ? stack.last[1] : root_creative
          c = Creative.create(user: user, parent: new_parent, description: desc)
          created << c
          i += 1
        else
          i += 1
        end
      end
      if created.any?
        { success: true, created: created.map(&:id) }
      else
        { error: "No creatives created" }
      end
    end

    def export(parent_id: nil)
      creatives = if parent_id
        Creative.where(id: parent_id)&.map(&:effective_origin) || []
      else
        Creative.where(parent_id: nil)
      end
      ApplicationController.helpers.render_creative_tree_markdown(creatives)
    end

    private

    def markdown_table_to_html(lines, index, image_refs, helpers)
      return nil unless lines[index] =~ /^\s*\|.*\|\s*$/
      return nil if index + 1 >= lines.size
      return nil unless lines[index + 1] =~ /^\s*\|[-:| ]+\|\s*$/
      headers = lines[index].strip.split("|")[1..-1].map { |h| h.strip }
      i = index + 2
      rows = []
      while i < lines.size && lines[i] =~ /^\s*\|.*\|\s*$/
        rows << lines[i].strip.split("|")[1..-1].map { |c| c.strip }
        i += 1
      end
      html = "<table><thead><tr>" +
             headers.map { |h| "<th>#{helpers.markdown_links_to_html(h, image_refs)}</th>" }.join +
             "</tr></thead><tbody>" +
             rows.map { |r| "<tr>" + r.map { |c| "<td>#{helpers.markdown_links_to_html(c, image_refs)}</td>" }.join + "</tr>" }.join +
             "</tbody></table>"
      [ html, i ]
    end
  end
end
