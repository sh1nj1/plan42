module Collavre
  # Paragraph defaults follow the same placeholder hierarchy as run defaults.
  module PptParagraphs
    private

    def paragraph_format(paragraph, namespaces, counters = {})
      properties = effective_paragraph_properties(paragraph, namespaces)
      defaults = properties&.at_xpath("./a:defRPr", namespaces) || paragraph.at_xpath("./a:endParaRPr", namespaces)
      values = text_format(defaults, namespaces)
      values[:align] = properties&.[]("algn")
      values[:bullet] = paragraph_marker(paragraph, properties, namespaces, counters)
      values.merge(paragraph_spacing(properties, namespaces)).merge(paragraph_indentation(properties))
    end

    def effective_paragraph_properties(paragraph, namespaces)
      local = paragraph.at_xpath("./a:pPr", namespaces)
      shape = paragraph.ancestors.find { |node| node.name == "sp" }
      level = (local&.[]("lvl").to_i + 1).clamp(1, 9)
      merge_run_properties((text_style_sources(shape, level) + [ local ]).compact)
    end

    def paragraph_indentation(properties)
      { marginLeft: "marL", textIndent: "indent" }.each_with_object({}) do |(key, attribute), values|
        raw = properties&.[](attribute)
        next unless raw&.match?(/\A[+-]?[0-9]+\z/)

        value = raw.to_i * 100.0 / @slide_size.first
        minimum = key == :textIndent ? -100 : 0
        values[key] = value if value.finite? && value.between?(minimum, 100)
      end
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
