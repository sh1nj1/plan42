require "test_helper"

class PptFormattingTest < ActiveSupport::TestCase
  setup do
    @renderer = Object.new.extend(Collavre::PptShapeFills).extend(Collavre::PptShapeStyles).extend(Collavre::PptFormatting).extend(Collavre::PptInheritance)
  end

  test "resolves font tokens and rejects missing and unsafe font names" do
    theme = xml('<a:fontScheme><a:majorFont><a:latin typeface="Cambria"/><a:ea typeface="맑은 고딕"/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme>')
    @renderer.instance_variable_set(:@theme, theme)
    { "+mj-lt" => "Cambria", "+mn-lt" => "Aptos", "+mj-ea" => "맑은 고딕", "+mj-cs" => "Arial", "Times New Roman" => "Times New Roman" }.each do |input, expected|
      assert_equal expected, @renderer.send(:resolved_font, input)
    end
    [ nil, "", "+mn-ea", "+unknown", 'Arial; color:red', 'Font"', "x" * 101, "Font\n" ].each do |input|
      assert_nil @renderer.send(:resolved_font, input)
    end
    @renderer.instance_variable_set(:@theme, nil)
    assert_nil @renderer.send(:resolved_font, "+mj-lt")
  end

  test "selects validated script faces and resolves their theme tokens" do
    @renderer.instance_variable_set(:@theme, xml('<a:fontScheme><a:majorFont><a:ea typeface="맑은 고딕"/><a:cs typeface="Amiri"/></a:majorFont></a:fontScheme>'))
    properties = xml('<a:rPr><a:latin typeface="Arial"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:rPr>').root.element_children.first
    namespaces = properties.document.collect_namespaces
    { "Hello" => "Arial", "한글" => "맑은 고딕", "مرحبا" => "Amiri" }.each do |text, expected|
      assert_equal expected, @renderer.send(:run_font, properties, namespaces, text)
    end
    properties.at_xpath('./a:latin', namespaces).remove
    assert_equal "맑은 고딕", @renderer.send(:run_font, properties, namespaces, "")
    properties.at_xpath('./a:ea', namespaces)['typeface'] = 'bad; color:red'
    assert_equal "Amiri", @renderer.send(:run_font, properties, namespaces, "한글")
    properties.at_xpath('./a:cs', namespaces)['typeface'] = ''
    assert_nil @renderer.send(:run_font, properties, namespaces, "مرحبا")
  end

  test "shape property merge keeps source XML immutable and replaces exclusive choices" do
    master = xml('<p:spPr bwMode="auto"><a:solidFill/><a:prstGeom prst="ellipse"/><a:ln w="100"><a:solidFill/></a:ln></p:spPr>').root.element_children.first
    layout = xml('<p:spPr bwMode="black"><a:gradFill/><a:custGeom/><a:ln><a:noFill/></a:ln></p:spPr>').root.element_children.first
    original = master.to_xml
    merged = @renderer.send(:merge_shape_properties, nil, master)
    merged = @renderer.send(:merge_shape_properties, merged, layout)
    assert_equal original, master.to_xml
    assert_equal "black", merged["bwMode"]
    assert_equal %w[gradFill custGeom ln], merged.element_children.map(&:name)
    assert_equal "100", merged.element_children.last["w"]
    assert_equal [ "noFill" ], merged.element_children.last.element_children.map(&:name)
    shape = xml('<p:sp><p:spPr><a:noFill/></p:spPr></p:sp>').root.element_children.first
    @renderer.instance_variable_set(:@rendering_inherited, true)
    assert_equal [ "noFill" ], @renderer.send(:effective_shape_properties, shape).element_children.map(&:name)
    assert_nil @renderer.send(:effective_shape_properties, xml('<p:sp/>').root.element_children.first)
  end

  test "run fill choices replace each other without mutating sources" do
    %w[noFill gradFill blipFill pattFill grpFill solidFill].each do |variant|
      inherited = xml('<a:rPr sz="2400"><a:solidFill/><a:latin typeface="Arial"/></a:rPr>').root.element_children.first
      local = xml("<a:rPr><a:#{variant}/></a:rPr>").root.element_children.first
      original = inherited.to_xml
      merged = @renderer.send(:merge_run_properties, [ inherited, local ])
      assert_equal [ "latin", variant ], merged.element_children.map(&:name)
      assert_equal "2400", merged["sz"]
      assert_equal original, inherited.to_xml
    end
  end

  private

  def xml(content)
    Nokogiri::XML('<root xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' + content + '</root>')
  end
end
