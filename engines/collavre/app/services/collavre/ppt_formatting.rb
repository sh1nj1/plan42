module Collavre
  # Presentation formatting is stored as data, never as unrestricted CSS.
  # The browser validates each field before applying it inside a slide canvas.
  module PptFormatting
    private

    def format_attribute(values)
      %( data-ppt-format="#{ERB::Util.html_escape(values.compact.to_json)}")
    end

    def ppt_color(node)
      color = node&.at_xpath("./a:srgbClr", node.document.collect_namespaces)&.[]("val")
      "##{color}" if color&.match?(/\A[0-9a-f]{6}\z/i)
    end

    def geometry_format(node, namespaces, bounds)
      transform = transform_for(node, namespaces)
      return {} unless transform

      x, y, width, height = transform
      bw, bh, ox, oy = bounds
      { x: (x - ox.to_i) * 100.0 / bw, y: (y - oy.to_i) * 100.0 / bh,
        w: width * 100.0 / bw, h: height * 100.0 / bh }
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

    def paragraph_format(paragraph, namespaces)
      properties = paragraph.at_xpath("./a:pPr", namespaces)
      defaults = properties&.at_xpath("./a:defRPr", namespaces) || paragraph.at_xpath("./a:endParaRPr", namespaces)
      values = text_format(defaults, namespaces)
      values[:align] = properties&.[]("algn")
      after = properties&.at_xpath("./a:spcAft/a:spcPts", namespaces)
      values[:spaceAfter] = after["val"].to_f * 127 * 100 / @slide_size.first if after
      values[:bullet] = properties&.at_xpath("./a:buChar", namespaces)&.[]("char")
      spacing = properties&.at_xpath("./a:lnSpc/a:spcPct", namespaces)
      values[:lineHeight] = spacing["val"].to_f / 100_000 if spacing
      values
    end
  end
end
