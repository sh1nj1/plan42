module Collavre
  # SmartArt data fallback: preserve authored labels and hierarchy as a list.
  module PptDiagrams
    private

    def render_diagram(relationship)
      return unless relationship && relationship[:type].end_with?("/diagramData")

      document = xml_document(relationship[:path])
      return unless document

      namespaces = document.collect_namespaces.merge("dgm" => "http://schemas.openxmlformats.org/drawingml/2006/diagram")
      points = document.xpath("/dgm:dataModel/dgm:ptLst/dgm:pt", namespaces).select do |point|
        [ nil, "node", "doc", "asst" ].include?(point["type"])
      end.index_by { |point| point["modelId"] }
      children = diagram_children(document, namespaces, points)
      targets = children.values.flatten
      roots = points.keys - targets
      visited = Set.new
      content = (roots + points.keys).map do |id|
        diagram_item(id, points, children, namespaces, visited, 0)
      end.join
      %(<ul class="ppt-slide-diagram">#{content}</ul>) if content.present?
    end

    def diagram_children(document, namespaces, points)
      edges = document.xpath("/dgm:dataModel/dgm:cxnLst/dgm:cxn", namespaces).select do |edge|
        [ nil, "parOf" ].include?(edge["type"]) && points.key?(edge["srcId"]) && points.key?(edge["destId"])
      end
      edges.sort_by { |edge| edge["srcOrd"].to_i }.group_by { |edge| edge["srcId"] }
        .transform_values { |items| items.map { |edge| edge["destId"] }.uniq }
    end

    def diagram_item(id, points, children, namespaces, visited, depth)
      return "" unless visited.add?(id)
      raise self.class::InvalidArchive if depth > 64

      point = points.fetch(id)
      label = render_paragraphs(point.at_xpath("./dgm:t", namespaces), namespaces).join
      descendants = children.fetch(id, []).map do |child|
        diagram_item(child, points, children, namespaces, visited, depth + 1)
      end.join
      return descendants if point["type"] == "doc" && label.blank?
      return "" if label.blank? && descendants.blank?

      nested = descendants.present? ? "<ul>#{descendants}</ul>" : ""
      "<li>#{label}#{nested}</li>"
    end
  end
end
