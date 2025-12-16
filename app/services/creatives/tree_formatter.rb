module Creatives
  class TreeFormatter
    def format(creatives)
      roots = Array(creatives)
      lines = []

      roots.each do |root|
        format_node(root, 0, lines)
      end

      lines.join("\n")
    end

    private

    def format_node(node, depth, lines)
      indent = " " * (depth * 4)
      desc = ActionController::Base.helpers.strip_tags(node.effective_description(nil, false))
      progress = node.progress || 0.0

      node_data = { id: node.id, progress: progress, desc: desc }
      lines << "#{indent}- #{node_data.to_json}"

      # We need to handle children. If the node is a new instance (in tests),
      # children might depend on how it's set up.
      # In real app, we use children association.
      # To match the logic in views/controllers where we might want specific ordering:
      # We'll validly assume `children` association is available.
      node.children.each do |child|
        format_node(child, depth + 1, lines)
      end
    end
  end
end
