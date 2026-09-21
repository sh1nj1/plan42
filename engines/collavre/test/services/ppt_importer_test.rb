require "test_helper"
require "base64"
require "zip"

class PptImporterTest < ActiveSupport::TestCase
  SAMPLE_IMAGE = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=")

  test "rejects missing or wrong-type slide relationships without partial imports" do
    [ presentation_relationships_xml.sub(/<Relationship Id="rId2"[^>]+\/>/, ""),
      presentation_relationships_xml.sub('relationships/slide" Target="slides/slide2.xml', 'relationships/notesSlide" Target="slides/slide2.xml') ].each do |relationships|
      Tempfile.create([ "incomplete", ".pptx" ]) do |tmp|
        Zip::OutputStream.open(tmp.path) do |zip|
          write_entry(zip, "ppt/presentation.xml", presentation_xml)
          write_entry(zip, "ppt/_rels/presentation.xml.rels", relationships)
          write_entry(zip, "ppt/slides/slide1.xml", slide_xml("First"))
          write_entry(zip, "ppt/slides/slide2.xml", slide_xml("Second"))
        end
        Creative::RealtimeBroadcastable.stub(:broadcast_batch_created, ->(*) { flunk "must not broadcast" }) do
          assert_no_difference("Creative.count") do
            assert_raises(PptImporter::InvalidArchive) do
              PptImporter.import(tmp, parent: nil, user: users(:one), create_root: true)
            end
          end
        end
      end
    end
  end

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

  test "preserves significant whitespace after persistence" do
    text = "  indented  code\n    next line"
    with_archive("ppt/slides/slide1.xml" => slide_xml(text)) do |file|
      created = import_file(file)
      assert_equal text, Nokogiri::HTML.fragment(created.last.reload.description).at_css("p").text
    end
  end

  test "inherits placeholder geometry from layout and master" do
    slide = slide_xml("Inherited").sub("<p:txBody>", '<p:nvSpPr><p:nvPr><p:ph idx="4"/></p:nvPr></p:nvSpPr><p:txBody>')
    layout = rich_slide_xml.sub('type="title"', 'type="title" idx="4"')
    rels = relationships_xml("slideLayout", "../slideLayouts/layout.xml")
    with_archive("ppt/slides/slide1.xml" => slide,
                 "ppt/slides/_rels/slide1.xml.rels" => rels,
                 "ppt/slideLayouts/layout.xml" => layout) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert html.at_css(".ppt-slide-text.ppt-col-2.ppt-row-2.ppt-col-span-11")
    end

    layout_without_transform = layout.sub(/<p:spPr>.*?<\/p:spPr>/m, "")
    with_archive("ppt/slides/slide1.xml" => slide,
                 "ppt/slides/_rels/slide1.xml.rels" => rels,
                 "ppt/slideLayouts/layout.xml" => layout_without_transform,
                 "ppt/slideLayouts/_rels/layout.xml.rels" => relationships_xml("slideMaster", "../slideMasters/master.xml"),
                 "ppt/slideMasters/master.xml" => rich_slide_xml) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert html.at_css(".ppt-slide-text.ppt-col-2.ppt-row-2")
    end
  end

  test "preserves merged table cells and skips continuation cells" do
    slide = rich_slide_xml.sub('<a:tc>', '<a:tc gridSpan="2" rowSpan="2">')
                          .sub('<a:tc><a:txBody><a:p><a:r><a:t>Beta', '<a:tc hMerge="1"><a:txBody><a:p><a:r><a:t>Beta')
                          .sub('</a:tbl>', '<a:tr><a:tc vMerge="true"/><a:tc hMerge="1" vMerge="1"/></a:tr></a:tbl>')
    with_archive("ppt/slides/slide1.xml" => slide) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal 1, html.css(".ppt-slide-table td").size
      assert_equal "2", html.at_css(".ppt-slide-table td")["colspan"]
      assert_equal "2", html.at_css(".ppt-slide-table td")["rowspan"]
    end
  end

  test "subtracts group child origins before placing children" do
    slide = rich_slide_xml.sub('<a:chOff x="0" y="0"/>', '<a:chOff x="1000000" y="2000000"/>')
                          .sub('<a:off x="0" y="0"/>', '<a:off x="1000000" y="2000000"/>')
    with_archive("ppt/slides/slide1.xml" => slide) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert html.at_css(".ppt-slide-group .ppt-col-1.ppt-row-1.ppt-col-span-12.ppt-row-span-12")
    end
  end

  test "rejects empty archives without creating or broadcasting a root" do
    with_archive("readme.txt" => "empty") do |file|
      Creative::RealtimeBroadcastable.stub(:broadcast_batch_created, ->(*) { flunk "Unexpected broadcast" }) do
        assert_no_difference("Creative.count") do
          assert_raises(PptImporter::InvalidArchive) { import_file(file) }
        end
      end
    end
  end

  test "rejects archives exceeding entry count individual size and total size limits" do
    [ :MAX_ENTRIES, :MAX_ENTRY_BYTES, :MAX_TOTAL_BYTES ].each do |constant|
      original = PptImporter.const_get(constant)
      PptImporter.send(:remove_const, constant)
      PptImporter.const_set(constant, 1)
      with_archive("ppt/slides/slide1.xml" => slide_xml("Large"), "extra" => "x") do |file|
        assert_no_difference("Creative.count") do
          assert_raises(PptImporter::InvalidArchive) { import_file(file) }
        end
      end
    ensure
      PptImporter.send(:remove_const, constant)
      PptImporter.const_set(constant, original)
    end
  end

  test "bounds actual decompression even when entry metadata understates size" do
    importer = PptImporter.new(nil, parent: nil, user: users(:one), create_root: false, filename: nil)
    importer.instance_variable_set(:@read_bytes, 0)
    entry = Object.new
    entry.define_singleton_method(:get_input_stream) { |&block| block.call(StringIO.new("x" * (PptImporter::MAX_ENTRY_BYTES + 1))) }
    assert_raises(PptImporter::InvalidArchive) { importer.send(:read_entry, entry) }
  end

  test "rolls back records and removes uploaded bytes when a later slide is corrupt" do
    blobs = []
    original = ActiveStorage::Blob.method(:build_after_unfurling)
    track = ->(**args) { original.call(**args).tap { |blob| blobs << blob } }
    with_archive("ppt/slides/slide1.xml" => rich_slide_xml,
                 "ppt/slides/_rels/slide1.xml.rels" => rich_slide_relationships_xml,
                 "ppt/media/image1.png" => SAMPLE_IMAGE,
                 "ppt/slides/slide2.xml" => "<invalid") do |file|
      Creative::RealtimeBroadcastable.stub(:broadcast_batch_created, ->(*) { flunk "Unexpected broadcast" }) do
        ActiveStorage::Blob.stub(:build_after_unfurling, track) do
          assert_no_difference([ "Creative.count", "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ]) do
            assert_raises(Nokogiri::XML::SyntaxError) { import_file(file) }
          end
        end
      end
    end
    assert_equal 1, blobs.size
    assert_not blobs.first.service.exist?(blobs.first.key)
  end

  test "keeps explicit line breaks and unmatched placeholders readable" do
    slide = slide_xml("First").sub("</a:r></a:p>", "</a:r><a:br/><a:r><a:t>Second</a:t></a:r></a:p>")
                             .sub("<p:txBody>", '<p:nvSpPr><p:nvPr><p:ph idx="99"/></p:nvPr></p:nvSpPr><p:txBody>')
    with_archive("ppt/slides/slide1.xml" => slide,
                 "ppt/slides/_rels/slide1.xml.rels" => relationships_xml("slideLayout", "../slideLayouts/layout.xml"),
                 "ppt/slideLayouts/layout.xml" => rich_slide_xml) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal 1, html.css("p br").size
      assert_equal "FirstSecond", html.at_css("p").text
    end
  end

  test "cleans up a partially uploaded image on storage failure" do
    blob = nil
    original = ActiveStorage::Blob.method(:build_after_unfurling)
    fail_upload = lambda do |**args|
      blob = original.call(**args)
      blob.define_singleton_method(:upload_without_unfurling) do |io|
        service.upload(key, io, checksum: checksum)
        raise IOError, "Upload interrupted"
      end
      blob
    end
    with_archive("ppt/slides/slide1.xml" => rich_slide_xml,
                 "ppt/slides/_rels/slide1.xml.rels" => rich_slide_relationships_xml,
                 "ppt/media/image1.png" => SAMPLE_IMAGE) do |file|
      ActiveStorage::Blob.stub(:build_after_unfurling, fail_upload) do
        assert_no_difference([ "Creative.count", "ActiveStorage::Blob.count" ]) do
          assert_raises(IOError) { import_file(file) }
        end
      end
    end
    assert_not blob.service.exist?(blob.key)
  end

  test "pairs sparse chart categories and values by point index in numeric order" do
    chart = Nokogiri::XML(chart_xml)
    chart.at_xpath("//*[local-name()='strCache']").inner_html = <<~XML
      <c:pt idx="10"><c:v>Q11</c:v></c:pt>
      <c:pt idx="2"><c:v>Q3</c:v></c:pt>
      <c:pt idx="0"><c:v>Q1</c:v></c:pt>
    XML
    chart.at_xpath("//*[local-name()='numCache']").inner_html = <<~XML
      <c:pt idx="2"><c:v>30</c:v></c:pt>
      <c:pt idx="0"><c:v>10</c:v></c:pt>
      <c:pt idx="1"><c:v>20</c:v></c:pt>
    XML

    with_archive("ppt/slides/slide1.xml" => rich_slide_xml,
                 "ppt/slides/_rels/slide1.xml.rels" => rich_slide_relationships_xml,
                 "ppt/charts/chart1.xml" => chart.to_xml) do |file|
      slide = import_file(file).last.reload
      html = Nokogiri::HTML.fragment(slide.description)
      assert_equal "Q1: 10, 20, Q3: 30, Q11", html.at_css(".ppt-slide-chart td").text
    end
  end

  private

  def import_file(file)
    PptImporter.import(file, parent: nil, user: users(:one), create_root: true)
  end

  def with_archive(entries)
    Tempfile.create([ "review", ".pptx" ]) do |tmp|
      Zip::OutputStream.open(tmp.path) do |zip|
        entries.each { |path, content| write_entry(zip, path, content) }
      end
      tmp.rewind
      yield tmp
    end
  end

  def relationships_xml(type, target)
    %(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/#{type}" Target="#{target}"/></Relationships>)
  end


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
