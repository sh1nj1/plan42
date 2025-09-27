module Creatives
  class PathExporter
    Entry = Struct.new(:creative_id, :path, :path_with_ids, keyword_init: true)

    def initialize(creative)
      @creative = creative.effective_origin
    end

    def paths
      entries.map(&:path)
    end

    def paths_with_ids
      entries.map(&:path_with_ids)
    end

    def path_for(id)
      entry_map[id.to_i]&.path
    end

    def path_with_ids_for(id)
      entry_map[id.to_i]&.path_with_ids
    end

    private

    def entries
      @entries ||= begin
        results = []
        traverse(@creative, [], [], results)
        results
      end
    end

    def entry_map
      @entry_map ||= entries.index_by(&:creative_id)
    end

    def traverse(node, ancestors, ancestors_with_ids, results)
      label = extract_label(node)
      label_with_id = "[#{node.id}] #{label}"
      current_path = (ancestors + [ label ]).join(" > ")
      current_path_with_ids = (ancestors_with_ids + [ label_with_id ]).join(" > ")

      results << Entry.new(
        creative_id: node.id,
        path: current_path,
        path_with_ids: current_path_with_ids
      )

      node.children.order(:sequence).each do |child|
        traverse(child, ancestors + [ label ], ancestors_with_ids + [ label_with_id ], results)
      end
    end

    def extract_label(creative)
      html = creative.effective_description(nil, true).to_s
      sanitized = ActionView::Base.full_sanitizer.sanitize(html).to_s
      text = sanitized.gsub(/[\r\n]+/, " ").squeeze(" ").strip
      text.presence || "Creative ##{creative.id}"
    end
  end
end
