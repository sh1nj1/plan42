class MarkdownImporter
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
      if line =~ /^(#+)\s+(.*)$/
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
end
