module Creatives
  class PathExporter
    Entry = Struct.new(
      :creative_id,
      :progress,
      :path,
      :path_with_ids,
      :path_with_ids_and_progress,
      :full_path_with_ids,
      :full_path_with_ids_and_progress,
      :leaf,
      keyword_init: true
    )

    def initialize(creative, use_effective_origin: true)
      @creative = use_effective_origin ? creative.effective_origin : creative
    end

    def paths
      entries.map(&:path)
    end

    def paths_with_ids
      entries.map(&:path_with_ids)
    end

    def paths_with_ids_and_progress
      entries.map(&:path_with_ids_and_progress)
    end

    def path_for(id)
      entry_map[id.to_i]&.path
    end

    def path_with_ids_for(id)
      entry_map[id.to_i]&.path_with_ids
    end

    def path_with_ids_and_progress_for(id)
      entry_map[id.to_i]&.path_with_ids_and_progress
    end

    def full_paths_with_ids
      entries.map(&:full_path_with_ids)
    end

    def full_paths_with_ids_and_progress
      entries.map(&:full_path_with_ids_and_progress)
    end

    def full_path_with_ids_for(id)
      entry_map[id.to_i]&.full_path_with_ids
    end

    def full_path_with_ids_and_progress_for(id)
      entry_map[id.to_i]&.full_path_with_ids_and_progress
    end

    def full_paths_with_ids_and_progress_with_leaf
      entries.map do |entry|
        {
          path: entry.full_path_with_ids_and_progress,
          leaf: entry.leaf
        }
      end
    end

    private

    def entries
      @entries ||= begin
        results = []
        traverse(@creative, [], [], [], results)
        results
      end
    end

    def entry_map
      @entry_map ||= entries.index_by(&:creative_id)
    end

    def traverse(node, ancestors, ancestors_with_ids, ancestors_with_ids_and_progress, results)
      label = extract_label(node)
      label_with_id = "[#{node.id}] #{label}"
      label_with_progress = label_with_progress(node, label_with_id)
      current_path = (ancestors + [ label ]).join(" > ")
      current_path_with_ids = (ancestors_with_ids + [ label_with_id ]).join(" > ")
      current_path_with_ids_and_progress = (ancestors_with_ids_and_progress + [ label_with_progress ]).join(" > ")

      children = node.children.order(:sequence).to_a

      results << Entry.new(
        creative_id: node.id,
        progress: node.progress,
        path: current_path,
        path_with_ids: label_with_id,
        path_with_ids_and_progress: label_with_progress,
        full_path_with_ids: current_path_with_ids,
        full_path_with_ids_and_progress: current_path_with_ids_and_progress,
        leaf: children.empty?
      )

      children.each do |child|
        traverse(
          child,
          ancestors + [ label ],
          ancestors_with_ids + [ label_with_id ],
          ancestors_with_ids_and_progress + [ label_with_progress ],
          results
        )
      end
    end

    def extract_label(creative)
      html = creative.effective_description(nil, true).to_s
      sanitized = ActionView::Base.full_sanitizer.sanitize(html).to_s
      text = sanitized.gsub(/[\r\n]+/, " ").squeeze(" ").strip
      text.presence || "Creative ##{creative.id}"
    end

    def label_with_progress(node, base_label)
      progress = node.progress
      return base_label if progress.nil?

      percentage = (progress.to_f * 100).round
      "#{base_label} (progress #{percentage}%)"
    end
  end
end
