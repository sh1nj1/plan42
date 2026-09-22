require "test_helper"

class PptMediaTest < ActiveSupport::TestCase
  setup do
    @renderer = Object.new.extend(Collavre::PptMedia).extend(Collavre::PptArchive)
  end

  test "bounds hyperlink schemes syntax and size" do
    %w[https://example.com http://example.com/path mailto:person@example.com].each do |url|
      assert @renderer.send(:safe_hyperlink?, url)
    end
    [ "https://", "javascript:alert(1)", "file:///x", "//example.com", "https://example.com/\n", "https://example.com/\\x", "https://example.com/%ZZ", "x" * 4097 ].each do |url|
      assert_not @renderer.send(:safe_hyperlink?, url), url
    end
  end

  test "rejects non external and missing relationships" do
    document = Nokogiri::XML('<r xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><rPr><hlinkClick r:id="link"/></rPr></r>')
    @renderer.instance_variable_set(:@xml_cache, { "slide.xml" => document })
    [ {}, { "link" => { external: false, type: "x/hyperlink" } }, { "link" => { external: true, type: "x/image" } } ].each do |rels|
      @renderer.stub(:relationships_for, rels) { assert_equal "Label", @renderer.send(:linked_run, document.root, "Label") }
    end
  end

  test "validates crop syntax bounds default sides and nonempty source area" do
    assert_equal [ 0.25, 0, 0, 0 ], crop('l="25000"')
    assert_equal [ -0.5, 0, 0, 0 ], crop('l="-50000"')
    assert_equal [ 0, 0, 0, 0 ], crop("")
    [ 'l="1.5"', 'l="100001"', 'l="-100001"', 'l="50000" r="50000"', 't="100000"', 'b="NaN"', 'r="1;foo"' ].each do |attributes|
      assert_nil crop(attributes)
    end
    assert_nil @renderer.send(:picture_crop, Nokogiri::XML("<pic/>").root)
  end

  def crop(attributes)
    picture = Nokogiri::XML("<pic><blipFill><srcRect #{attributes}/></blipFill></pic>").root
    @renderer.send(:picture_crop, picture)
  end
end
