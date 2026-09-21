require "test_helper"

class PptColorsTest < ActiveSupport::TestCase
  setup do
    @renderer = Object.new.extend(Collavre::PptColors)
    @theme = xml('<a:theme><a:themeElements><a:clrScheme><a:accent1><a:srgbClr val="204060"/></a:accent1><a:accent2><a:srgbClr val="804020"/></a:accent2><a:lt1><a:sysClr lastClr="FFFFFF"/></a:lt1></a:clrScheme></a:themeElements></a:theme>')
    @renderer.instance_variable_set(:@theme, @theme)
  end

  test "applies tint shade and luminance modifiers in document order" do
    assert_equal "#90A0B0", color('<a:schemeClr val="accent1"><a:tint val="50000"/></a:schemeClr>')
    assert_equal "#102030", color('<a:schemeClr val="accent1"><a:shade val="50000"/></a:schemeClr>')
    assert_equal "#102030", color('<a:schemeClr val="accent1"><a:lumMod val="50000"/></a:schemeClr>')
    assert_equal "#204060", color('<a:schemeClr val="accent1"><a:lumMod val="50000"/><a:lumOff val="12549"/></a:schemeClr>')
    assert_equal "#404040", color('<a:srgbClr val="808080"><a:lumMod val="50000"/></a:srgbClr>')
    assert_equal "#FFFFFF", color('<a:srgbClr val="204060"><a:lumOff val="900000"/></a:srgbClr>')
    assert_equal "#484848", color('<a:srgbClr val="202020"><a:tint val="50000"/><a:shade val="50000"/></a:srgbClr>')
  end

  test "handles absent invalid and unsupported colors without unsafe serialization" do
    assert_nil @renderer.send(:ppt_color, nil)
    assert_nil color('<a:schemeClr val="missing"/>')
    assert_nil color('<a:srgbClr val="red; color:blue"/>')
    assert_nil color('<a:prstClr val="red"/>')
    assert_equal "#204060", color('<a:srgbClr val="204060"><a:alpha val="100000"/><a:shade val="bad"/></a:srgbClr>')
    assert_equal "#123456", color('<a:sysClr val="windowText" lastClr="123456"/>')
    assert_equal "#FFFFFF", color('<a:schemeClr val="bg1"/>')
    @renderer.instance_variable_set(:@theme, nil)
    assert_nil color('<a:schemeClr val="accent1"/>')
  end

  test "honors slide then layout maps and explicit master mapping" do
    master = xml('<p:sldMaster><p:clrMap accent1="accent2"/></p:sldMaster>')
    layout = xml('<p:sldLayout><p:clrMapOvr><a:overrideClrMapping accent1="accent1"/></p:clrMapOvr></p:sldLayout>')
    slide = xml('<p:sld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>')
    @renderer.instance_variable_set(:@color_documents, [ slide, layout, master ])
    assert_equal "#804020", color('<a:schemeClr val="accent1"/>')
    @renderer.instance_variable_set(:@color_documents, [ xml('<p:sld/>'), layout, master ])
    assert_equal "#204060", color('<a:schemeClr val="accent1"/>')
    @renderer.instance_variable_set(:@color_documents, [ xml('<p:sld/>'), master ])
    assert_equal "#804020", color('<a:schemeClr val="accent1"/>')
  end

  private

  def xml(content)
    Nokogiri::XML('<root xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' + content + '</root>')
  end

  def color(content)
    @renderer.send(:ppt_color, xml("<a:solidFill>#{content}</a:solidFill>").at_xpath('//*[local-name()="solidFill"]'))
  end
end
