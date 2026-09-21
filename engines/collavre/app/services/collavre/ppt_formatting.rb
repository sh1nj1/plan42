module Collavre
  # Presentation formatting is stored as data, never as unrestricted CSS.
  # The browser validates each field before applying it inside a slide canvas.
  module PptFormatting
    private

    def format_attribute(values)
      %( data-ppt-format="#{ERB::Util.html_escape(values.compact.to_json)}")
    end

    def geometry_format(node, namespaces, bounds)
      transform = transform_for(node, namespaces)
      return {} unless transform

      x, y, width, height, orientation = transform
      bw, bh, ox, oy = bounds
      { x: (x - ox.to_i) * 100.0 / bw, y: (y - oy.to_i) * 100.0 / bh,
        w: width * 100.0 / bw, h: height * 100.0 / bh }.merge(orientation_format(orientation))
    end

    def shape_format(shape, namespaces, bounds)
      values = geometry_format(shape, namespaces, bounds)
      properties = shape.at_xpath("./p:spPr", namespaces)
      values[:fill] = ppt_color(properties&.at_xpath("./a:solidFill", namespaces))
      line = properties&.at_xpath("./a:ln", namespaces)
      values[:stroke] = ppt_color(line&.at_xpath("./a:solidFill", namespaces))
      values[:strokeWidth] = line["w"].to_f * 100 / @slide_size.first if line
      geometry = properties&.at_xpath("./a:prstGeom", namespaces)
      values[:shape] = geometry&.[]("prst")
      body = shape.at_xpath("./p:txBody/a:bodyPr", namespaces)
      if body
        values[:anchor] = body["anchor"] || "t"
        values[:insets] = %w[lIns tIns rIns bIns].map.with_index do |key, i|
          (body[key] || (i.even? ? 91_440 : 45_720)).to_f * 100 / @slide_size.first
        end
      end
      values
    end

    def text_format(properties, namespaces)
      return {} unless properties

      values = { color: ppt_color(properties.at_xpath("./a:solidFill", namespaces)) }
      values[:fontSize] = properties["sz"].to_f * 127 * 100 / @slide_size.first if properties["sz"]
      values[:font] = properties.at_xpath("./a:latin", namespaces)&.[]("typeface")
      values
    end

    def line_chart_format(chart, series)
      return unless chart.at_xpath("//*[local-name()='lineChart']")

      axis = chart.at_xpath("//*[local-name()='valAx']")
      minimum = axis&.at_xpath("./*[local-name()='scaling']/*[local-name()='min']")&.[]("val")
      maximum = axis&.at_xpath("./*[local-name()='scaling']/*[local-name()='max']")&.[]("val")
      { series: series, min: minimum && Float(minimum, exception: false),
        max: maximum && Float(maximum, exception: false) }
    end

    def orientation_format(transform)
      values = {}
      rotation = Float(transform["rot"], exception: false)
      values[:rotation] = (rotation / 60_000) % 360 if rotation&.finite?
      %w[flipH flipV].each { |key| values[key] = truthy_xml_attribute?(transform[key]) if transform[key] }
      values
    end
  end
end
