require_relative "../test_helper"

class NotionBlockBatchesTest < ActiveSupport::TestCase
  test "empty content sends no requests" do
    assert_empty batches([])
  end

  test "paragraph requests respect bytes and count while preserving multibyte and escaped text" do
    [ "가", "😀", "\"\\\n" ].each do |character|
      blocks = exported(character * 200_000)
      result = batches(blocks)
      assert_operator result.size, :>, 1
      assert_equal blocks, result.flatten
      assert_valid_requests(result)
    end
    assert_equal [ 100, 1 ], batches(exported("x" * 202_000)).map(&:size)
  end

  test "request envelope counts toward the exact byte boundary" do
    block = { type: "paragraph", paragraph: { rich_text: [] } }
    block[:padding] = "x" * (500_000 - { children: [ block.merge(padding: "") ] }.to_json.bytesize)
    assert_equal 500_000, { children: [ block ] }.to_json.bytesize
    assert_equal [ [ block ] ], batches([ block ])
    block[:padding] += "x"
    assert_raises(CollavreNotion::NotionError) { batches([ block ]) }
  end

  test "table requests split oversized rows and retain every column in order" do
    values = [ "가" * 200_001, "😀" * 180_000, "\"\\" * 150_000 ]
    html = "<p>Before</p><table><tr>#{values.map { |value| "<td>#{value}</td>" }.join}</tr>" \
           "<tr><td>next</td><td></td><td>end</td></tr></table><p>After</p>"
    blocks = exported(html)
    original = Marshal.dump(blocks)
    result = batches(blocks)
    assert_valid_requests(result)
    assert_equal original, Marshal.dump(blocks), "partitioning must not mutate the exported content digest"
    assert_equal blocks.first, result.first.sole
    assert_equal blocks.last, result.last.sole
    tables = result.flatten.select { |block| block[:type] == "table" }
    assert_operator tables.size, :>, 2
    assert_equal [ true ] + [ false ] * (tables.size - 1), tables.map { |table| table.dig(:table, :has_column_header) }
    assert tables.all? { |table| table.dig(:table, :table_width) == 3 }
    rows = tables.flat_map { |table| table.dig(:table, :children) }
    assert rows.all? { |row| row.dig(:table_row, :cells).size == 3 }
    values.each_with_index do |value, column|
      actual = rows[0...-1].flat_map { |row| row.dig(:table_row, :cells, column) }.map { |text| text.dig(:text, :content) }.join
      assert_equal value, actual
    end
    assert_equal "next", rows.last.dig(:table_row, :cells, 0, 0, :text, :content)
    assert_equal "end", rows.last.dig(:table_row, :cells, 2, 0, :text, :content)
  end

  test "table rows that fit individually are partitioned by total serialized size" do
    html = "<table>#{('<tr><td>' + '😀' * 2_000 + '</td></tr>') * 100}</table>"
    blocks = exported(html)
    result = batches(blocks)
    assert_operator result.size, :>, 1
    assert_equal [ true ] + [ false ] * (result.size - 1), result.map { |batch| batch.sole.dig(:table, :has_column_header) }
    assert_valid_requests(result)
    assert_equal blocks.sole.dig(:table, :children), result.flat_map { |batch| batch.sole.dig(:table, :children) }
  end


  test "headerless tables remain headerless after byte partitioning" do
    table = exported("<table>#{('<tr><td>' + '😀' * 2_000 + '</td></tr>') * 100}</table>").sole
    table[:table][:has_column_header] = false
    result = batches([ table ])
    assert_operator result.size, :>, 1
    assert result.all? { |batch| batch.sole.dig(:table, :has_column_header) == false }
    assert_valid_requests(result)
  end

  test "an indivisible oversized table row fails without recursive looping" do
    table = exported("<table><tr><td>x</td></tr></table>").sole
    table[:table][:children].sole[:table_row][:cells][0][0][:text][:content] = "x" * 500_000
    assert_raises(CollavreNotion::NotionError) { batches([ table ]) }
  end

  private

  def exported(html)
    creative = Struct.new(:effective_description).new(html)
    CollavreNotion::NotionCreativeExporter.new(creative).export_blocks
  end

  def batches(blocks)
    result = []
    CollavreNotion::NotionBlockBatches.new.each(blocks) { |batch| result << batch }
    result
  end

  def assert_valid_requests(result)
    result.each do |batch|
      assert_operator({ children: batch }.to_json.bytesize, :<=, 500_000)
      assert_operator batch.size, :<=, 100
      nested = batch.sum { |block| 1 + Array(block.dig(:table, :children)).size }
      assert_operator nested, :<=, 1_000
      batch.select { |block| block[:type] == "table" }.each do |table|
        assert_operator table.dig(:table, :children).size, :<=, 100
        table.dig(:table, :children).each do |row|
          row.dig(:table_row, :cells).each { |cell| assert_operator cell.size, :<=, 100 }
        end
      end
    end
  end
end
