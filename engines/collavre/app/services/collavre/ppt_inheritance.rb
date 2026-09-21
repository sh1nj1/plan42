module Collavre
  # Resolve slide inheritance without mutating the shared XML parts.
  module PptInheritance
    private

    def inherited_parts(relationships)
      parts = []
      %w[slideLayout slideMaster].each do |type|
        relationship = relationships.values.find { |item| item[:type].end_with?("/#{type}") }
        break unless relationship

        document = xml_document(relationship[:path])
        break unless document

        relationships = relationships_for(relationship[:path])
        parts << { document: document, relationships: relationships }
      end
      parts
    end

    def render_inherited_shapes(slide)
      return "" if %w[0 false off].include?(slide.root["showMasterSp"])

      parts = @inherited_parts.to_a
      parts = parts.first(1) if %w[0 false off].include?(parts.first&.dig(:document)&.root&.[]("showMasterSp"))
      @rendering_inherited = true
      parts.reverse.map do |part|
        document = part[:document]
        namespaces = document.collect_namespaces
        tree = document.at_xpath("//p:cSld/p:spTree", namespaces)
        tree ? render_nodes(tree.element_children, namespaces, part[:relationships], @slide_size) : ""
      end.join
    ensure
      @rendering_inherited = false
    end

    def compatibility_branch(node)
      supported = %w[http://schemas.openxmlformats.org/presentationml/2006/main http://schemas.openxmlformats.org/drawingml/2006/main http://schemas.openxmlformats.org/drawingml/2006/chart]
      node.element_children.find do |child|
        child.name == "Choice" && child["Requires"].present? && child["Requires"].split.all? do |prefix|
          supported.include?(child.namespaces["xmlns:#{prefix}"])
        end
      end || node.element_children.find { |child| child.name == "Fallback" }
    end

    def inherited_placeholders(node)
      placeholder = node.at_xpath(".//*[local-name()='ph']")
      return [] unless placeholder

      @placeholder_sources.to_a.filter_map.with_index do |source, index|
        candidates = source.xpath("//*[local-name()='ph']")
        match = if index.zero?
          candidates.find { |candidate| candidate["idx"].to_i == placeholder["idx"].to_i }
        else
          candidates.find { |candidate| (candidate["type"] || "obj") == (placeholder["type"] || "obj") }
        end
        next unless match

        placeholder = match
        match.parent.parent.parent
      end
    end

    def effective_run_properties(run, namespaces)
      paragraph = run.parent
      shape = paragraph.ancestors.find { |node| node.name == "sp" }
      level = (paragraph.at_xpath("./a:pPr", namespaces)&.[]("lvl").to_i + 1).clamp(1, 9)
      sources = text_style_sources(shape, level)
      properties = sources.flat_map do |source|
        source.xpath("./a:defRPr", source.document.collect_namespaces).to_a
      end
      properties << paragraph.at_xpath("./a:pPr/a:defRPr", namespaces)
      properties << run.at_xpath("./a:rPr", namespaces)
      merge_run_properties(properties.compact)
    end

    def text_style_sources(shape, level)
      presentation = xml_document("ppt/presentation.xml")
      sources = presentation ? presentation.xpath("//*[local-name()='defaultTextStyle']/*[local-name()='lvl#{level}pPr']").to_a : []
      return sources unless shape

      placeholders = inherited_placeholders(shape)
      sources.concat(master_text_styles(shape, placeholders, level))
      (placeholders.reverse + [ shape ]).each do |item|
        ns = item.document.collect_namespaces
        sources.concat(item.xpath("./p:txBody/a:lstStyle/a:lvl#{level}pPr", ns).to_a)
        next if item == shape

        paragraph = item.xpath("./p:txBody/a:p", ns).find { |p| p.at_xpath("./a:pPr", ns)&.[]("lvl").to_i == level - 1 }
        sources << paragraph.at_xpath("./a:pPr", ns) if paragraph
      end
      sources.compact
    end

    def master_text_styles(shape, placeholders, level)
      type = ([ shape ] + placeholders).filter_map { |item| item.at_xpath(".//*[local-name()='ph']")&.[]("type") }.first
      style = case type
      when "title", "ctrTitle" then "titleStyle"
      when "body", "subTitle", "obj" then "bodyStyle"
      else "otherStyle"
      end
      master = @inherited_parts.to_a.second&.dig(:document)
      master ? master.xpath("//*[local-name()='txStyles']/*[local-name()='#{style}']/*[local-name()='lvl#{level}pPr']").to_a : []
    end

    def merge_run_properties(properties)
      return if properties.empty?

      merged = properties.first.dup
      properties.drop(1).each do |source|
        source.attribute_nodes.each { |attribute| merged[attribute.name] = attribute.value }
        source.element_children.each do |child|
          names = %w[buNone buChar buAutoNum].include?(child.name) ? %w[buNone buChar buAutoNum] : [ child.name ]
          merged.element_children.select { |existing| names.include?(existing.name) }.each(&:remove)
          merged.add_child(child.dup)
        end
      end
      merged
    end
  end
end
