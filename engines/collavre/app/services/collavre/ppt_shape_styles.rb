module Collavre
  # Theme matrix styles provide defaults beneath explicit shape properties.
  module PptShapeStyles
    private

    def theme_text_properties(shape)
      return unless shape

      style = effective_shape_properties(shape, "./p:style")
      reference = style&.at_xpath("./*[local-name()='fontRef']")
      return unless reference && %w[major minor].include?(reference["idx"])

      properties = Nokogiri::XML::Node.new("rPr", shape.document)
      properties.namespace = shape.document.root.namespace_definitions.find { |ns| ns.prefix == "a" }
      font = resolved_font(reference["idx"] == "major" ? "+mj-lt" : "+mn-lt")
      if font
        latin = Nokogiri::XML::Node.new("latin", shape.document)
        latin.namespace = properties.namespace
        latin["typeface"] = font
        properties.add_child(latin)
      end
      if ppt_color(reference)
        fill = Nokogiri::XML::Node.new("solidFill", shape.document)
        fill.namespace = properties.namespace
        reference.element_children.each { |color| fill.add_child(color.dup) }
        properties.add_child(fill)
      end
      properties
    end

    def theme_shape_properties(shape)
      style = effective_shape_properties(shape, "./p:style")
      return unless style && @theme

      properties = Nokogiri::XML::Node.new("spPr", shape.document)
      %w[fillRef lnRef].each do |name|
        reference = style.element_children.find { |child| child.name == name }
        entry = shape_style_entry(reference, name)
        properties.add_child(copy_shape_properties(entry)) if entry
      end
      properties
    end

    def shape_style_entry(reference, name)
      value = reference&.[]("idx")
      return unless value&.match?(/\A[0-9]{1,10}\z/)

      index = value.to_i
      return if index.zero? || index == 1000

      list_name, offset = if name == "lnRef"
        [ "lnStyleLst", 1 ]
      elsif index > 1000
        [ "bgFillStyleLst", 1001 ]
      else
        [ "fillStyleLst", 1 ]
      end
      list = @theme.at_xpath("//*[local-name()='fmtScheme']/*[local-name()='#{list_name}']")
      entry = list&.element_children&.[](index - offset)&.dup
      resolve_style_placeholders(entry, reference) if entry
    end

    def resolve_style_placeholders(entry, reference)
      color = reference.element_children.find { |child| %w[srgbClr schemeClr sysClr].include?(child.name) }
      entry.xpath(".//*[local-name()='schemeClr' and @val='phClr']").each do |placeholder|
        return unless color && ppt_color(reference)

        replacement = color.dup
        placeholder.element_children.each { |modifier| replacement.add_child(modifier.dup) }
        placeholder.replace(replacement)
      end
      entry
    end
  end
end
