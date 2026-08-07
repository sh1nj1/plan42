require "test_helper"
require "base64"
require "zip"

class PptImporterTest < ActiveSupport::TestCase
  SAMPLE_IMAGE = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=")

  test "preserves presentation order and slide structure as responsive html" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Root")
    Creative.create!(user: user, parent: parent, description: "Existing", sequence: 4)
    broadcasted = nil

    Tempfile.create([ "sample", ".pptx" ]) do |tmp|
      build_sample_pptx(tmp)
      tmp.rewind

      Creative::RealtimeBroadcastable.stub(:broadcast_batch_created, ->(items) { broadcasted = items }) do
        assert_difference -> { ActiveStorage::Blob.count }, +1 do
          @created = PptImporter.import(tmp, parent: parent, user: user, create_root: false)
        end
      end
    end

    assert_equal 2, @created.length
    assert_equal [ 5, 6 ], @created.map(&:sequence)
    assert_equal @created, broadcasted

    # presentation.xml orders slide2 before slide1, independent of filenames.
    assert_includes @created.first.description, "Second slide"

    structured = @created.second.reload
    html = Nokogiri::HTML.fragment(structured.description)
    slide = html.at_css(".ppt-slide")
    assert_equal "2", slide["data-ppt-slide"]
    assert_equal "12192000", slide["data-ppt-width"]
    assert slide["class"].include?("ppt-slide--wide")
    assert html.at_css(".ppt-slide-title.ppt-col-2.ppt-row-2")
    assert_equal "Title & intro", html.at_css(".ppt-slide-title").text.strip
    assert html.at_css(".ppt-slide-group .ppt-slide-text"), "group hierarchy should remain nested"

    image = html.at_css(".ppt-slide-image img")
    assert_match(%r{\A/public-assets/blobs/}, image["src"])
    assert_equal "Product screenshot", image["alt"]
    assert_no_match(/data:image/, structured.description)
    assert_equal 1, structured.files.count

    assert_equal %w[Alpha Beta], html.css(".ppt-slide-table td").map { |cell| cell.text.strip }
    assert_equal "Revenue", html.at_css(".ppt-slide-chart h3").text.strip
    assert_includes html.at_css(".ppt-slide-chart").text, "Q1: 10"
    assert_equal "Speaker notes", html.at_css(".ppt-slide-notes h3").text.strip
    assert_includes html.at_css(".ppt-slide-notes").text, "Remember the demo"
  end

  test "creates an escaped root and broadcasts it before its slides" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Root")
    broadcasted = nil

    Tempfile.create([ "sample", ".pptx" ]) do |tmp|
      build_minimal_pptx(tmp)
      tmp.rewind

      Creative::RealtimeBroadcastable.stub(:broadcast_batch_created, ->(items) { broadcasted = items }) do
        @created = PptImporter.import(
          tmp,
          parent: parent,
          user: user,
          create_root: true,
          filename: "<Quarterly>.pptx"
        )
      end
    end

    root, slide = @created
    assert_equal "&lt;Quarterly&gt;", root.description
    assert_equal root, slide.parent
    assert_equal [ root, slide ], broadcasted
  end

  test "falls back to numeric slide filenames when presentation metadata is absent" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Root")

    Tempfile.create([ "sample", ".pptx" ]) do |tmp|
      Zip::OutputStream.open(tmp.path) do |zip|
        write_entry(zip, "ppt/slides/slide10.xml", slide_xml("Ten"))
        write_entry(zip, "ppt/slides/slide2.xml", slide_xml("Two"))
      end
      tmp.rewind

      Creative::RealtimeBroadcastable.stub(:broadcast_batch_created, nil) do
        @created = PptImporter.import(tmp, parent: parent, user: user)
      end
    end

    assert_equal [ "Two", "Ten" ], @created.map { |creative| Nokogiri::HTML.fragment(creative.description).text.strip }
  end

  private

  def build_sample_pptx(tmp)
    Zip::OutputStream.open(tmp.path) do |zip|
      write_entry(zip, "ppt/presentation.xml", presentation_xml)
      write_entry(zip, "ppt/_rels/presentation.xml.rels", presentation_relationships_xml)
      write_entry(zip, "ppt/slides/slide1.xml", rich_slide_xml)
      write_entry(zip, "ppt/slides/_rels/slide1.xml.rels", rich_slide_relationships_xml)
      write_entry(zip, "ppt/slides/slide2.xml", slide_xml("Second slide"))
      write_entry(zip, "ppt/media/image1.png", SAMPLE_IMAGE)
      write_entry(zip, "ppt/charts/chart1.xml", chart_xml)
      write_entry(zip, "ppt/notesSlides/notesSlide1.xml", notes_xml)
    end
  end

  def build_minimal_pptx(tmp)
    Zip::OutputStream.open(tmp.path) do |zip|
      write_entry(zip, "ppt/slides/slide1.xml", slide_xml("Only slide"))
    end
  end

  def write_entry(zip, path, content)
    zip.put_next_entry(path)
    zip.write(content)
  end

  def presentation_xml
    <<~XML
      <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:sldIdLst>
          <p:sldId id="257" r:id="rId2"/>
          <p:sldId id="256" r:id="rId1"/>
        </p:sldIdLst>
        <p:sldSz cx="12192000" cy="6858000"/>
      </p:presentation>
    XML
  end

  def presentation_relationships_xml
    <<~XML
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
      </Relationships>
    XML
  end

  def slide_xml(text)
    <<~XML
      <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
             xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
        <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>#{text}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
      </p:sld>
    XML
  end

  def rich_slide_xml
    <<~XML
      <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
             xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
             xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
             xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">
        <p:cSld><p:spTree>
          <p:sp>
            <p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="609600" y="342900"/><a:ext cx="5486400" cy="685800"/></a:xfrm></p:spPr>
            <p:txBody><a:p><a:r><a:rPr b="1"/><a:t>Title &amp; intro</a:t></a:r></a:p></p:txBody>
          </p:sp>
          <p:pic>
            <p:nvPicPr><p:cNvPr name="Screenshot" descr="Product screenshot"/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rIdImage"/></p:blipFill>
            <p:spPr><a:xfrm><a:off x="6096000" y="342900"/><a:ext cx="5486400" cy="2743200"/></a:xfrm></p:spPr>
          </p:pic>
          <p:graphicFrame>
            <p:xfrm><a:off x="609600" y="1714500"/><a:ext cx="4876800" cy="1371600"/></p:xfrm>
            <a:graphic><a:graphicData><a:tbl>
              <a:tr><a:tc><a:txBody><a:p><a:r><a:t>Alpha</a:t></a:r></a:p></a:txBody></a:tc>
                    <a:tc><a:txBody><a:p><a:r><a:t>Beta</a:t></a:r></a:p></a:txBody></a:tc></a:tr>
            </a:tbl></a:graphicData></a:graphic>
          </p:graphicFrame>
          <p:graphicFrame>
            <p:xfrm><a:off x="609600" y="3429000"/><a:ext cx="4876800" cy="1714500"/></p:xfrm>
            <a:graphic><a:graphicData><c:chart r:id="rIdChart"/></a:graphicData></a:graphic>
          </p:graphicFrame>
          <p:grpSp>
            <p:grpSpPr><a:xfrm><a:off x="6096000" y="3429000"/><a:ext cx="4876800" cy="1714500"/><a:chOff x="0" y="0"/><a:chExt cx="4876800" cy="1714500"/></a:xfrm></p:grpSpPr>
            <p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="2438400" cy="857250"/></a:xfrm></p:spPr>
              <p:txBody><a:p><a:r><a:t>Grouped text</a:t></a:r></a:p></p:txBody></p:sp>
          </p:grpSp>
        </p:spTree></p:cSld>
      </p:sld>
    XML
  end

  def rich_slide_relationships_xml
    <<~XML
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdImage" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
        <Relationship Id="rIdChart" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart1.xml"/>
        <Relationship Id="rIdNotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide1.xml"/>
      </Relationships>
    XML
  end

  def chart_xml
    <<~XML
      <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"
                    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
        <c:chart><c:title><c:tx><c:rich><a:p><a:r><a:t>Revenue</a:t></a:r></a:p></c:rich></c:tx></c:title>
          <c:plotArea><c:barChart><c:ser><c:tx><c:v>Sales</c:v></c:tx>
            <c:cat><c:strRef><c:strCache><c:pt idx="0"><c:v>Q1</c:v></c:pt></c:strCache></c:strRef></c:cat>
            <c:val><c:numRef><c:numCache><c:pt idx="0"><c:v>10</c:v></c:pt></c:numCache></c:numRef></c:val>
          </c:ser></c:barChart></c:plotArea>
        </c:chart>
      </c:chartSpace>
    XML
  end

  def notes_xml
    <<~XML
      <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
        <p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>
          <p:txBody><a:p><a:r><a:t>Remember the demo</a:t></a:r></a:p></p:txBody>
        </p:sp></p:spTree></p:cSld>
      </p:notes>
    XML
  end
end
