module Collavre
  # Paragraph defaults follow the same placeholder hierarchy as run defaults.
  module PptParagraphs
    private

    def paragraph_format(paragraph, namespaces)
      properties = effective_paragraph_properties(paragraph, namespaces)
      defaults = properties&.at_xpath("./a:defRPr", namespaces) || paragraph.at_xpath("./a:endParaRPr", namespaces)
      values = text_format(defaults, namespaces)
      values[:align] = properties&.[]("algn")
      values[:bullet] = properties&.at_xpath("./a:buChar", namespaces)&.[]("char")
      values.merge(paragraph_spacing(properties, namespaces))
    end

    def effective_paragraph_properties(paragraph, namespaces)
      local = paragraph.at_xpath("./a:pPr", namespaces)
      shape = paragraph.ancestors.find { |node| node.name == "sp" }
      level = (local&.[]("lvl").to_i + 1).clamp(1, 9)
      merge_run_properties((text_style_sources(shape, level) + [ local ]).compact)
    end

    def paragraph_spacing(properties, namespaces)
      return {} unless properties

      values = {}
      { spaceBefore: "spcBef", spaceAfter: "spcAft", lineHeight: "lnSpc" }.each do |key, name|
        spacing = properties.at_xpath("./a:#{name}", namespaces)&.element_children&.first
        next unless spacing

        if spacing.name == "spcPts"
          key = :lineHeightPoints if key == :lineHeight
          values[key] = spacing["val"].to_f * 127 * 100 / @slide_size.first
        elsif spacing.name == "spcPct"
          key = :"#{key}Em" unless key == :lineHeight
          values[key] = spacing["val"].to_f / 100_000
        end
      end
      values
    end
  end
end
