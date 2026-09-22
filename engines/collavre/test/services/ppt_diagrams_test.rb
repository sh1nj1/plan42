require "test_helper"
require "zip"

class PptDiagramsTest < ActiveSupport::TestCase
  test "persists SmartArt labels hierarchy sibling order and frame geometry" do
    points = point("root", nil, "doc") + point("parent", "Parent &amp; &lt;script&gt;") + point("second", "Second") + point("first", "First", "asst") + point("layout", "Duplicate", "pres")
    edges = edge("root", "parent") + edge("parent", "second", 1) + edge("parent", "first", 0)
    html = import_diagram(points, edges)
    list = html.at_css(".ppt-slide-diagram")
    assert list, "SmartArt must survive import and sanitization"
    assert_equal "Parent & <script>", list.at_css("li > p").text
    assert_equal [ "First", "Second" ], list.css("li > ul > li > p").map(&:text)
    assert_equal 3, list.css("li").size
    assert_empty html.css("script")
    assert_not_includes html.text, "Duplicate"
    format = JSON.parse(html.at_css(".ppt-slide-graphic")["data-ppt-format"])
    assert_equal [ 10, 10, 50, 50 ], format.values_at("x", "y", "w", "h")
  end

  test "retains disconnected nodes and terminates cyclic duplicate and dangling edges" do
    points = point("a", "A") + point("b", "B") + point("c", "C", "node") + point("empty", nil)
    edges = edge("a", "b") + edge("b", "a") + edge("a", "b") + edge("a", "missing") + edge("missing", "c") + edge("c", "a", 0, "presOf")
    html = import_diagram(points, edges)
    assert_equal [ "C", "A", "B" ], html.css(".ppt-slide-diagram p").map(&:text)
    assert_equal 3, html.css(".ppt-slide-diagram li").size
  end

  test "handles absent data invalid relationship type and empty diagrams" do
    [ { missing: true }, { relationship_type: "chart" }, { relationship: false }, {} ].each do |options|
      html = import_diagram("", "", **options)
      assert_empty html.css(".ppt-slide-diagram, .ppt-slide-graphic")
    end
  end

  test "retains labelled document points and unlabelled parents" do
    html = import_diagram(point("root", "Title", "doc") + point("empty", nil) + point("child", "Child"), edge("root", "empty") + edge("empty", "child"))
    assert_equal "Title", html.at_css(".ppt-slide-diagram > li > p").text
    assert_equal "Child", html.at_css(".ppt-slide-diagram > li > ul > li > ul > li > p").text
  end

  test "rejects excessive hierarchy depth without persisting a partial slide" do
    points = (0..66).map { |id| point(id, "Node #{id}") }.join
    edges = (0...66).map { |id| edge(id, id + 1) }.join
    assert_no_difference("Creative.count") do
      assert_raises(Collavre::PptImporter::InvalidArchive) { import_diagram(points, edges) }
    end
  end

  private

  def point(id, text, type = nil)
    body = text ? "<dgm:t><a:p><a:r><a:t>#{text}</a:t></a:r></a:p></dgm:t>" : ""
    %(<dgm:pt modelId="#{id}"#{type ? %( type="#{type}") : ""}>#{body}</dgm:pt>)
  end

  def edge(source, target, order = 0, type = nil)
    %(<dgm:cxn srcId="#{source}" destId="#{target}" srcOrd="#{order}"#{type ? %( type="#{type}") : ""}/>)
  end

  def import_diagram(points, edges, missing: false, relationship: true, relationship_type: "diagramData")
    Tempfile.create([ "diagram", ".pptx" ]) do |file|
      Zip::OutputStream.open(file.path) do |zip|
        zip.put_next_entry("ppt/slides/slide1.xml")
        zip.write <<~XML
          <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram">
          <p:cSld><p:spTree><p:graphicFrame><p:xfrm><a:off x="1219200" y="685800"/><a:ext cx="6096000" cy="3429000"/></p:xfrm><a:graphic><a:graphicData><dgm:relIds r:dm="diagram"/></a:graphicData></a:graphic></p:graphicFrame></p:spTree></p:cSld></p:sld>
        XML
        if relationship
          zip.put_next_entry("ppt/slides/_rels/slide1.xml.rels")
          zip.write %(<Relationships><Relationship Id="diagram" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/#{relationship_type}" Target="../diagrams/data1.xml"/></Relationships>)
        end
        unless missing
          zip.put_next_entry("ppt/diagrams/data1.xml")
          zip.write %(<dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dgm:ptLst>#{points}</dgm:ptLst><dgm:cxnLst>#{edges}</dgm:cxnLst></dgm:dataModel>)
        end
      end
      Nokogiri::HTML.fragment(Collavre::PptImporter.import(file, parent: nil, user: users(:one)).first.reload.description)
    end
  end
end
