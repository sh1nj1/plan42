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
      properties = effective_shape_properties(shape)
      values[:fill] = ppt_color(properties&.at_xpath("./a:solidFill", namespaces))
      line = properties&.at_xpath("./a:ln", namespaces)
      values[:stroke] = ppt_color(line&.at_xpath("./a:solidFill", namespaces))
      values[:strokeWidth] = line["w"].to_f * 100 / @slide_size.first if line
      geometry = properties&.at_xpath("./a:prstGeom", namespaces)
      values[:shape] = geometry&.[]("prst")
      body = effective_shape_properties(shape, "./p:txBody/a:bodyPr")
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
      values[:noFill] = true if properties.at_xpath("./a:noFill", namespaces)
      values[:fontSize] = properties["sz"].to_f * 127 * 100 / @slide_size.first if properties["sz"]
      values[:font] = resolved_font(properties.at_xpath("./a:latin", namespaces)&.[]("typeface"))
      values
    end

    def effective_shape_properties(shape, path = "./p:spPr")
      inherited = @rendering_inherited ? [] : inherited_placeholders(shape).reverse
      properties = (inherited + [ shape ]).filter_map do |source|
        source.at_xpath(path, source.document.collect_namespaces)
      end
      base = path == "./p:spPr" ? theme_shape_properties(shape) : nil
      properties.reduce(base) { |merged, source| merge_shape_properties(merged, source) }
    end

    def merge_shape_properties(merged, source)
      return source.dup unless merged

      source.attribute_nodes.each { |attribute| merged[attribute.name] = attribute.value }
      source.element_children.each do |child|
        choices = [ %w[noFill solidFill gradFill blipFill pattFill grpFill], %w[prstGeom custGeom] ]
        names = choices.find { |group| group.include?(child.name) } || [ child.name ]
        previous = merged.element_children.select { |existing| names.include?(existing.name) }
        replacement = child.name == "ln" ? merge_shape_properties(previous.first, child) : child.dup
        previous.each(&:remove)
        merged.add_child(replacement)
      end
      merged
    end

    def resolved_font(typeface)
      token = typeface&.match(/\A\+(mj|mn)-(lt|ea|cs)\z/)
      if token
        family = token[1] == "mj" ? "majorFont" : "minorFont"
        script = { "lt" => "latin", "ea" => "ea", "cs" => "cs" }.fetch(token[2])
        typeface = @theme&.at_xpath("//*[local-name()='fontScheme']/*[local-name()='#{family}']/*[local-name()='#{script}']")&.[]("typeface")
      end
      typeface if typeface&.match?(/\A[\p{L}\p{N}][\p{L}\p{N} ._-]{0,99}\z/)
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
