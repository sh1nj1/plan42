require "test_helper"

class PptBackgroundsTest < ActiveSupport::TestCase
  setup do
    @renderer = Object.new.extend(Collavre::PptColors).extend(Collavre::PptBackgrounds)
    @theme = xml('<a:theme><a:themeElements><a:fmtScheme><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"><a:shade val="50000"/></a:schemeClr></a:solidFill><a:solidFill><a:srgbClr val="123456"/></a:solidFill><a:noFill/></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>')
    @renderer.instance_variable_set(:@theme, @theme)
  end

  test "reuses theme fills without leaking reference colors between slides" do
    original = @theme.to_xml
    assert_equal "#102030", background('<p:bgRef idx="1001"><a:srgbClr val="204060"/></p:bgRef>')
    assert_equal "#402010", background('<p:bgRef idx="1001"><a:srgbClr val="804020"/></p:bgRef>')
    assert_equal "#123456", background('<p:bgRef idx="1002"/>')
    assert_equal original, @theme.to_xml
  end

  test "uses safe fallback for missing invalid and unsupported background references" do
    [ nil, "", "bad", "-1", "0", "1000", "1003", "9999", "1" ].each do |index|
      assert_equal "#ffffff", background(%(<p:bgRef idx="#{index}"/>))
    end
    assert_equal "#ffffff", background('<p:bgRef idx="1001"><a:srgbClr val="unsafe"/></p:bgRef>')
    @renderer.instance_variable_set(:@theme, xml('<a:theme/>'))
    assert_equal "#ffffff", background('<p:bgRef idx="1001"/>')
    @renderer.instance_variable_set(:@theme, nil)
    assert_equal "#ffffff", background('<p:bgRef idx="1001"/>')
    assert_equal "#ffffff", @renderer.send(:slide_background, xml('<p:sld/>'))
  end

  test "explicit empty background overrides inheritance even when master shapes are hidden" do
    master = xml('<p:sldMaster><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="123456"/></a:solidFill></p:bgPr></p:bg></p:cSld></p:sldMaster>')
    @renderer.instance_variable_set(:@inherited_parts, [ { document: master } ])
    assert_equal "#123456", @renderer.send(:slide_background, xml('<p:sld showMasterSp="0"><p:cSld/></p:sld>'))
    assert_equal "#ffffff", background('<p:bgPr><a:noFill/></p:bgPr>')
  end

  private

  def xml(content)
    Nokogiri::XML(content.sub(/\A<([^ >]+)/, '<\1 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'))
  end

  def background(content)
    @renderer.send(:slide_background, xml("<p:sld><p:cSld><p:bg>#{content}</p:bg></p:cSld></p:sld>"))
  end
end
