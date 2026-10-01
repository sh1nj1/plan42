module CollavreNotion
  # Measure the same JSON envelope and encoding used by NotionClient#append_blocks.
  class NotionBlockBatches
    MAX_BYTES = 500_000

    def each(blocks, &callback)
      blocks.slice_when { |left, right| left[:type] == "table" || right[:type] == "table" }.each do |group|
        if group.first[:type] == "table"
          each_table(group.first, &callback)
        else
          group.each_slice(100) { |batch| each_batch(batch, &callback) }
        end
      end
    end

    private

    def fits?(blocks)
      { children: blocks }.to_json.bytesize <= MAX_BYTES
    end

    def each_batch(blocks, &callback)
      return callback.call(blocks) if fits?(blocks)
      raise NotionError, "Notion block exceeds request size limit" if blocks.size == 1

      blocks.each_slice((blocks.size / 2.0).ceil) { |part| each_batch(part, &callback) }
    end

    # Keep tables in separate requests to also bound the nested block count.
    def each_table(table, &callback)
      continuation = table.merge(table: table[:table].merge(has_column_header: false))
      rows = table.dig(:table, :children).flat_map { |row| split_row(continuation, row) }
      rows.each_slice(100) { |part| each_table_rows(table, part, rows.first, &callback) }
    end

    def each_table_rows(table, rows, header_row, &callback)
      block = table_with_rows(table, rows)
      block[:table][:has_column_header] &&= rows.first.equal?(header_row)
      return callback.call([ block ]) if fits?([ block ])

      rows.each_slice((rows.size / 2.0).ceil) { |part| each_table_rows(table, part, header_row, &callback) }
    end

    def table_with_rows(table, rows)
      table.merge(table: table[:table].merge(children: rows))
    end

    # A single row can exceed the request budget. Split its rich-text objects
    # into continuation rows, leaving empty cells in the original column slots.
    def split_row(table, row)
      return [ row ] if fits?([ table_with_rows(table, [ row ]) ])

      cells = row.dig(:table_row, :cells)
      entries = cells.each_with_index.flat_map { |cell, column| cell.map { |text| [ column, text ] } }
      raise NotionError, "Notion table row exceeds request size limit" if entries.size <= 1

      entries.each_slice((entries.size / 2.0).ceil).flat_map do |part|
        continuation = Array.new(cells.size) { [] }
        part.each { |column, text| continuation[column] << text }
        split_row(table, row.merge(table_row: { cells: continuation }))
      end
    end
  end
end
