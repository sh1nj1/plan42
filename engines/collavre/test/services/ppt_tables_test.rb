require "test_helper"

class PptTablesTest < ActiveSupport::TestCase
  setup do
    @renderer = Collavre::PptImporter.allocate
  end

  test "rejects missing nonpositive nonfinite and excessive dimensions" do
    [ nil, "bad", "0", "-1", "NaN", "Infinity", "1000000001" ].each do |value|
      document = Nokogiri::XML('<table><column w="10"/><column/></table>')
      document.at_xpath('//column[2]')['w'] = value if value
      assert_nil @renderer.send(:table_proportions, document.xpath('//column'), 'w')
    end
    assert_nil @renderer.send(:table_proportions, [], 'w')
    document = Nokogiri::XML('<table><column w="1"/><column w="2"/></table>')
    assert_equal [ 100.0 / 3, 200.0 / 3 ], @renderer.send(:table_proportions, document.xpath('//column'), 'w')
  end
end
