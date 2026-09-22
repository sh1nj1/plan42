require "test_helper"

class PptShapeFillsTest < ActiveSupport::TestCase
  test "copies image provenance without trusting uploaded attributes or mutating XML" do
    importer = Collavre::PptImporter.allocate
    document = Nokogiri::XML('<spPr><blipFill data-source-part="untrusted"/></spPr>')
    original = document.to_xml
    importer.instance_variable_set(:@xml_cache, { "ppt/theme/theme1.xml" => document })
    copy = importer.send(:copy_shape_properties, document.root)
    assert_equal "ppt/theme/theme1.xml", copy.at_xpath("./blipFill")["data-source-part"]
    importer.instance_variable_set(:@xml_cache, {})
    assert_nil importer.send(:copy_shape_properties, document.root).at_xpath("./blipFill")["data-source-part"]
    importer.instance_variable_set(:@xml_cache, nil)
    assert_nil importer.send(:copy_shape_properties, document.root).at_xpath("./blipFill")["data-source-part"]
    assert_equal original, document.to_xml
  end
end
