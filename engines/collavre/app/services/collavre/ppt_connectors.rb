module Collavre
  # Connector SVG is reconstructed by the browser from bounded presentation data.
  module PptConnectors
    private

    def render_connector(node, namespaces, bounds)
      geometry = geometry_format(node, namespaces, bounds)
      classes = element_classes("ppt-slide-connector", transform_for(node, namespaces), bounds)
      geometry[:connector] = connector_format(node, namespaces)
      %(<div class="#{classes}"#{format_attribute(geometry)}></div>)
    end

    def connector_format(node, namespaces)
      properties = effective_shape_properties(node)
      line = properties&.at_xpath("./a:ln", namespaces)
      preset = properties&.at_xpath("./a:prstGeom", namespaces)
      transform = transform_for(node, namespaces)
      {
        slideWidth: @slide_size.first, kind: preset&.[]("prst") || "line", width: transform&.[](2), height: transform&.[](3),
        stroke: ppt_color(line&.at_xpath("./a:solidFill", namespaces)) || "#000000",
        hidden: line&.at_xpath("./a:noFill", namespaces).present?,
        weight: (line&.[]("w") || 12_700).to_f,
        head: connector_end(line&.at_xpath("./a:headEnd", namespaces)),
        tail: connector_end(line&.at_xpath("./a:tailEnd", namespaces)),
        adjustments: preset&.xpath("./a:avLst/a:gd", namespaces)&.to_h { |guide| [ guide["name"], guide["fmla"].to_s.delete_prefix("val ").to_f / 100_000 ] }
      }
    end

    def connector_end(node)
      { type: node&.[]("type"), width: node&.[]("w"), length: node&.[]("len") }
    end
  end
end
