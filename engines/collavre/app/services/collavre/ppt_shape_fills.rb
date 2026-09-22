module Collavre
  # Reuse validated background fills inside the shape's own geometry.
  module PptShapeFills
    private

    def shape_fill(properties)
      properties&.element_children&.find { |child| %w[solidFill gradFill pattFill blipFill].include?(child.name) }
    end

    def shape_fill_format(shape, properties, namespaces)
      transform = transform_for(shape, namespaces)
      size = transform ? transform[2, 2] : @slide_size
      fill_format(shape_fill(properties), size)
    end

    def shape_fill_picture(shape)
      fill = shape_fill(effective_shape_properties(shape))
      return "" unless fill&.name == "blipFill"

      picture_fill_markup(fill, "ppt-shape-fill ppt-slide-image", fill["data-source-part"])
    end

    # Capture provenance before Nokogiri moves copied fills into another document.
    # Never trust a similarly named attribute supplied in the uploaded XML.
    def copy_shape_properties(source)
      copy = source.dup
      part = @xml_cache&.key(source.document)
      copy.xpath("descendant-or-self::*[local-name()='blipFill']").each do |fill|
        fill.remove_attribute("data-source-part")
        fill["data-source-part"] = part if part
      end
      copy
    end
  end
end
