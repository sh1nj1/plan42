module Collavre
  # Theme matrix styles provide defaults beneath explicit shape properties.
  module PptShapeStyles
    private

    def theme_shape_properties(shape)
      style = effective_shape_properties(shape, "./p:style")
      return unless style && @theme

      properties = Nokogiri::XML::Node.new("spPr", shape.document)
      %w[fillRef lnRef].each do |name|
        reference = style.element_children.find { |child| child.name == name }
        entry = shape_style_entry(reference, name)
        properties.add_child(entry) if entry
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
