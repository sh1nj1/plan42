module Collavre
  # Convert slide and group coordinates into responsive bounds.
  module PptGeometry
    private

    def transform_for(node, namespaces)
      local_transform(node, namespaces) || inherited_transform(node)
    end

    def local_transform(node, namespaces)
      transform = transform_node(node, namespaces)
      return unless transform

      offset = transform.at_xpath("./a:off", namespaces)
      extent = transform.at_xpath("./a:ext", namespaces)
      return unless offset && extent

      [ offset["x"].to_i, offset["y"].to_i, extent["cx"].to_i, extent["cy"].to_i, transform ]
    end

    def transform_node(node, namespaces)
      case node.name
      when "graphicFrame"
        node.at_xpath("./p:xfrm", namespaces)
      when "grpSp"
        node.at_xpath("./p:grpSpPr/a:xfrm", namespaces)
      else
        node.at_xpath("./p:spPr/a:xfrm", namespaces)
      end
    end

    def placeholder_sources(relationships)
      @inherited_parts = inherited_parts(relationships)
      @inherited_parts.map { |part| part[:document] }
    end

    def inherited_transform(node)
      inherited_placeholders(node).each do |shape|
        transform = local_transform(shape, shape.document.collect_namespaces)
        return transform if transform
      end
      nil
    end

    def group_child_bounds(group, namespaces)
      transform = group.at_xpath("./p:grpSpPr/a:xfrm", namespaces)
      extent = transform&.at_xpath("./a:chExt", namespaces)
      width = extent&.[]("cx").to_i
      height = extent&.[]("cy").to_i
      offset = transform&.at_xpath("./a:chOff", namespaces)
      width.positive? && height.positive? ? [ width, height, offset&.[]("x").to_i, offset&.[]("y").to_i ] : @slide_size
    end

    def element_classes(kind, transform, bounds)
      classes = [ "ppt-slide-element", kind ]
      return classes.join(" ") unless transform

      x, y, width, height = transform
      bound_width, bound_height, origin_x, origin_y = bounds
      column = grid_start(x - origin_x.to_i, bound_width)
      row = grid_start(y - origin_y.to_i, bound_height)
      classes.concat([
        "ppt-col-#{column}",
        "ppt-col-span-#{grid_span(width, bound_width, column)}",
        "ppt-row-#{row}",
        "ppt-row-span-#{grid_span(height, bound_height, row)}"
      ])
      classes.join(" ")
    end

    def grid_start(offset, total)
      return 1 unless total.positive?

      ((offset.to_f / total) * self.class::GRID_SIZE).floor.clamp(0, self.class::GRID_SIZE - 1) + 1
    end

    def grid_span(length, total, start)
      return 1 unless total.positive?

      ((length.to_f / total) * self.class::GRID_SIZE).round.clamp(1, self.class::GRID_SIZE - start + 1)
    end

    def slide_ratio_class(width, height)
      ratio = width.to_f / height
      return "ppt-slide--portrait" if ratio < 0.9
      return "ppt-slide--square" if ratio < 1.2
      return "ppt-slide--standard" if ratio < 1.55

      "ppt-slide--wide"
    end
  end
end
