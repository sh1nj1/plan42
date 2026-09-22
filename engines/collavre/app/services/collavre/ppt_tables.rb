module Collavre
  # Keep authored table proportions in validated metadata through sanitization.
  module PptTables
    private

    def table_format(table, namespaces)
      { columns: table_proportions(table.xpath("./a:tblGrid/a:gridCol", namespaces), "w"),
        rows: table_proportions(table.xpath("./a:tr", namespaces), "h") }
    end

    def table_proportions(nodes, attribute)
      values = nodes.map { |node| Float(node[attribute], exception: false) }
      return unless values.any? && values.all? { |value| value && value.finite? && value.positive? && value <= 1e9 }

      total = values.sum
      values.map { |value| value * 100.0 / total }
    end

    def render_table(table, namespaces)
      rows = table.xpath("./a:tr", namespaces).map do |row|
        cells = row.xpath("./a:tc", namespaces).filter_map do |cell|
          next if truthy_xml_attribute?(cell["hMerge"]) || truthy_xml_attribute?(cell["vMerge"])

          content = render_paragraphs(cell.at_xpath("./a:txBody", namespaces), namespaces).join
          span = cell["gridSpan"].to_i
          colspan = span > 1 ? %( colspan="#{span}") : ""
          rowspan = cell["rowSpan"].to_i > 1 ? %( rowspan="#{cell["rowSpan"].to_i}") : ""
          "<td#{colspan}#{rowspan}>#{content}</td>"
        end
        "<tr>#{cells.join}</tr>"
      end
      %(<table class="ppt-slide-table"#{format_attribute(table_format(table, namespaces))}><tbody>#{rows.join}</tbody></table>)
    end
  end
end
