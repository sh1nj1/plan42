require "test_helper"

class PptShapeStylesTest < ActiveSupport::TestCase
  setup do
    @renderer = Collavre::PptImporter.allocate
    @theme = xml('<a:fmtScheme><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"><a:shade val="50000"/></a:schemeClr></a:solidFill><a:noFill/></a:fillStyleLst><a:lnStyleLst><a:ln w="12700"><a:solidFill><a:srgbClr val="112233"/></a:solidFill></a:ln></a:lnStyleLst><a:bgFillStyleLst><a:solidFill><a:srgbClr val="ABCDEF"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>')
    @renderer.instance_variable_set(:@theme, @theme)
  end

  test "validates indices and preserves literal entries without requiring placeholder colors" do
    [ nil, "", "-1", "1.0", "1junk", "99999999999", "0", "1000", "999" ].each do |index|
      reference = xml('<a:fillRef/>').root.element_children.first
      reference["idx"] = index if index
      assert_nil @renderer.send(:shape_style_entry, reference, "fillRef")
    end
    assert_nil @renderer.send(:shape_style_entry, nil, "fillRef")
    { [ "fillRef", "2" ] => "noFill", [ "fillRef", "1001" ] => "solidFill", [ "lnRef", "1" ] => "ln" }.each do |(name, index), expected|
      reference = xml("<a:#{name} idx=\"#{index}\"/>").root.element_children.first
      assert_equal expected, @renderer.send(:shape_style_entry, reference, name).name
    end
    @renderer.instance_variable_set(:@theme, xml('<a:fmtScheme/>'))
    assert_nil @renderer.send(:shape_style_entry, xml('<a:fillRef idx="1"/>').root.element_children.first, "fillRef")
  end

  test "resolves placeholder modifiers without mutating shared theme and reference XML" do
    reference = xml('<a:fillRef idx="1"><a:srgbClr val="804020"><a:alpha val="50000"/></a:srgbClr></a:fillRef>').root.element_children.first
    originals = [ @theme.to_xml, reference.to_xml ]
    entry = @renderer.send(:shape_style_entry, reference, "fillRef")
    assert_equal "#40201080", @renderer.send(:ppt_color, entry)
    assert_equal originals, [ @theme.to_xml, reference.to_xml ]
    [ '<a:fillRef idx="1"/>', '<a:fillRef idx="1"><a:srgbClr val="invalid"/></a:fillRef>' ].each do |content|
      assert_nil @renderer.send(:shape_style_entry, xml(content).root.element_children.first, "fillRef")
    end
  end

  test "inherits style references while local properties override theme defaults" do
    master = xml('<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:style><a:fillRef idx="1001"/><a:lnRef idx="1"/></p:style></p:sp>')
    shape = xml('<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:style><a:fillRef idx="2"/></p:style><p:spPr><a:ln w="0"><a:noFill/></a:ln></p:spPr></p:sp>').root.element_children.first
    @renderer.instance_variable_set(:@placeholder_sources, [ master ])
    properties = @renderer.send(:effective_shape_properties, shape)
    assert_equal %w[noFill ln], properties.element_children.map(&:name)
    assert_equal "0", properties.element_children.last["w"]
    assert_equal [ "noFill" ], properties.element_children.last.element_children.map(&:name)
    @renderer.instance_variable_set(:@theme, nil)
    assert_nil @renderer.send(:theme_shape_properties, shape)
  end

  test "connector rendering uses the theme outline and honors local noFill" do
    @renderer.instance_variable_set(:@slide_size, [ 1_219_200, 914_400 ])
    node = xml('<p:cxnSp><p:spPr><a:prstGeom prst="line"/></p:spPr><p:style><a:lnRef idx="1"/></p:style></p:cxnSp>').root.element_children.first
    data = @renderer.send(:connector_format, node, node.document.collect_namespaces)
    assert_equal "#112233", data[:stroke]
    assert_equal 12700, data[:weight]
    refute data[:hidden]
    node.at_xpath("./p:spPr", node.document.collect_namespaces).add_child('<a:ln xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" w="0"><a:noFill/></a:ln>')
    data = @renderer.send(:connector_format, node, node.document.collect_namespaces)
    assert data[:hidden]
    assert_equal 0, data[:weight]
  end

  test "cascades placeholder font references without changing shared XML" do
    @theme = xml('<a:fontScheme><a:majorFont><a:latin typeface="Cambria"/><a:ea typeface="맑은 고딕"/><a:cs typeface="Amiri"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme>')
    @renderer.instance_variable_set(:@theme, @theme)
    master = xml('<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:style><a:fontRef idx="major"><a:srgbClr val="112233"/></a:fontRef></p:style></p:sp>')
    shape = xml('<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr></p:sp>').root.element_children.first
    @renderer.instance_variable_set(:@placeholder_sources, [ master ])
    originals = [ master.to_xml, shape.to_xml, @theme.to_xml ]
    properties = @renderer.send(:theme_text_properties, shape)
    assert_equal 'Cambria', properties.at_xpath('./a:latin', shape.document.collect_namespaces)['typeface']
    assert_equal '#112233', @renderer.send(:ppt_color, properties.at_xpath('./a:solidFill', shape.document.collect_namespaces))
    assert_equal '맑은 고딕', @renderer.send(:run_font, properties, shape.document.collect_namespaces, '한국어')
    assert_equal 'Amiri', @renderer.send(:run_font, properties, shape.document.collect_namespaces, 'مرحبا')
    assert_equal originals, [ master.to_xml, shape.to_xml, @theme.to_xml ]
    shape.add_child('<p:style><a:fontRef idx="minor"/></p:style>')
    assert_equal 'Aptos', @renderer.send(:theme_text_properties, shape).element_children.first['typeface']
    @renderer.instance_variable_set(:@theme, nil)
    assert_empty @renderer.send(:theme_text_properties, shape).element_children
    shape.at_xpath('./p:style/a:fontRef', shape.document.collect_namespaces)['idx'] = 'unsafe'
    assert_nil @renderer.send(:theme_text_properties, shape)
    assert_nil @renderer.send(:theme_text_properties, nil)
  end

  private

  def xml(content)
    Nokogiri::XML('<root xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' + content + '</root>')
  end
end
