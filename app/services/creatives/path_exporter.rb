module Creatives
  class PathExporter
    def initialize(creative)
      @creative = creative.effective_origin
    end

    def paths
      traverse(@creative, []).compact
    end

    private

    def traverse(node, ancestors)
      label = extract_label(node)
      current_path = (ancestors + [ label ]).join(" > ")
      results = [ current_path ]
      node.children.order(:sequence).each do |child|
        results.concat(traverse(child, ancestors + [ label ]))
      end
      results
    end

    def extract_label(creative)
      html = creative.effective_description(nil, true).to_s
      sanitized = ActionView::Base.full_sanitizer.sanitize(html).to_s
      text = sanitized.gsub(/[\r\n]+/, " ").squeeze(" ").strip
      text.presence || "Creative ##{creative.id}"
    end
  end
end
