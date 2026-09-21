require "test_helper"
require "base64"
require "zip"

class PptImporterTest < ActiveSupport::TestCase
  SAMPLE_IMAGE = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=")

  test "preserves explicit tabs between runs fields and line breaks" do
    xml = slide_xml("Left").sub("</a:r>", '</a:r><a:tab/><a:tab/><a:fld><a:t>Right</a:t></a:fld><a:br/><a:tab/><a:r><a:t>Next</a:t></a:r>')
    html = import_connector_fixture(xml)
    assert_equal "Left\t\tRight\tNext", html.at_css("p").text
    assert_equal 1, html.css("p br").length
  end

  test "persists connector geometry stroke and arrows including grouped connectors" do
    connector = <<~XML
      <p:cxnSp><p:spPr><a:xfrm rot="5400000" flipH="1"><a:off x="1219200" y="685800"/><a:ext cx="6096000" cy="0"/></a:xfrm>
      <a:prstGeom prst="bentConnector3"><a:avLst><a:gd name="adj1" fmla="val 25000"/></a:avLst></a:prstGeom>
      <a:ln w="25400"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill><a:headEnd type="oval" w="sm" len="lg"/><a:tailEnd type="triangle"/></a:ln></p:spPr></p:cxnSp>
    XML
    html = import_connector_fixture(rich_slide_xml.sub("<p:spTree>", "<p:spTree>#{connector}").sub("</p:grpSp>", "#{connector}</p:grpSp>"))
    assert_equal 2, html.css(".ppt-slide-connector").length
    assert_equal 1, html.css(".ppt-slide-group .ppt-slide-connector").length
    format = JSON.parse(html.at_css(".ppt-slide-connector")["data-ppt-format"])
    assert_equal [ 10, 10, 50, 0, 90, true ], format.values_at("x", "y", "w", "h", "rotation", "flipH")
    data = format.fetch("connector")
    assert_equal [ "bentConnector3", 6096000, 0, "#FF0000", 25400, false ], data.values_at("kind", "width", "height", "stroke", "weight", "hidden")
    assert_equal({ "adj1" => 0.25 }, data["adjustments"])
    assert_equal({ "type" => "oval", "width" => "sm", "length" => "lg" }, data["head"])
    assert_equal "triangle", data["tail"]["type"]
  end

  test "keeps hidden and missing connector properties safe" do
    html = import_connector_fixture(slide_xml("Body").sub("<p:spTree>", '<p:spTree><p:cxnSp/><p:cxnSp><p:spPr><a:ln><a:noFill/></a:ln></p:spPr></p:cxnSp>'))
    first, second = html.css(".ppt-slide-connector").map { |node| JSON.parse(node["data-ppt-format"])["connector"] }
    assert_equal [ "line", nil, nil, "#000000", 12700, false ], first.values_at("kind", "width", "height", "stroke", "weight", "hidden")
    assert second["hidden"]
    assert_nil first["adjustments"]
  end

  def import_connector_fixture(xml)
    Tempfile.create([ "connector", ".pptx" ]) do |file|
      Zip::OutputStream.open(file.path) { |zip| write_entry(zip, "ppt/slides/slide1.xml", xml) }
      Nokogiri::HTML.fragment(PptImporter.import(file, parent: nil, user: users(:one)).first.reload.description)
    end
  end

  test "persists precise geometry and presentation formatting through sanitization" do
    xml = slide_xml("Readable")
      .sub("<p:cSld>", '<p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="222222"/></a:solidFill></p:bgPr></p:bg>')
      .sub("<p:sp>", <<~XML.strip)
        <p:sp><p:spPr><a:xfrm><a:off x="-121920" y="685800"/><a:ext cx="6096000" cy="1371600"/></a:xfrm>
        <a:prstGeom prst="roundRect"/><a:solidFill><a:srgbClr val="FEDF00"/></a:solidFill>
        <a:ln w="12700"><a:solidFill><a:srgbClr val="0062E5"/></a:solidFill></a:ln></p:spPr>
      XML
    xml = xml.sub("<p:txBody>", '<p:txBody><a:bodyPr anchor="ctr" lIns="0" tIns="0" rIns="0" bIns="0"/>')
      .sub("<a:p>", '<a:p><a:pPr algn="ctr"><a:buChar char="•"/><a:spcAft><a:spcPts val="1000"/></a:spcAft><a:lnSpc><a:spcPct val="120000"/></a:lnSpc><a:defRPr sz="2400"/></a:pPr>')
      .sub("<a:r>", '<a:r><a:rPr sz="2400"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:latin typeface="Malgun Gothic"/></a:rPr>')
    Tempfile.create([ "formatted", ".pptx" ]) do |tmp|
      Zip::OutputStream.open(tmp.path) { |zip| write_entry(zip, "ppt/slides/slide1.xml", xml) }
      creative = PptImporter.import(tmp, parent: nil, user: users(:one)).first.reload
      html = Nokogiri::HTML.fragment(creative.description)
      assert_equal({ "fill" => "#222222" }, JSON.parse(html.at_css(".ppt-slide")["data-ppt-format"]))
      shape = JSON.parse(html.at_css(".ppt-slide-text")["data-ppt-format"])
      assert_equal [ -1.0, 10.0, 50.0, 20.0 ], shape.values_at("x", "y", "w", "h")
      assert_equal [ "#FEDF00", "#0062E5", "roundRect", "ctr", [ 0, 0, 0, 0 ] ], shape.values_at("fill", "stroke", "shape", "anchor", "insets")
      assert_in_delta 0.104167, shape["strokeWidth"], 0.00001
      assert_equal({ "fontSize" => 2.5, "align" => "ctr", "spaceAfter" => 1000.0 / 960, "lineHeight" => 1.2 }, JSON.parse(html.at_css("p")["data-ppt-format"]))
      assert_equal({ "color" => "#FFFFFF", "fontSize" => 2.5, "font" => "Malgun Gothic" }, JSON.parse(html.at_css("span[data-ppt-format]")["data-ppt-format"]))
      assert_equal "• Readable", html.text.strip
    end
  end

  test "keeps unlabelled shapes and line chart data with explicit axis bounds" do
    Tempfile.create([ "chart", ".pptx" ]) do |tmp|
      xml = chart_xml.gsub("barChart", "lineChart").sub("</c:plotArea>", '<c:valAx><c:scaling><c:min val="0"/><c:max val="20"/></c:scaling></c:valAx></c:plotArea>')
      Zip::OutputStream.open(tmp.path) do |zip|
        write_entry(zip, "ppt/slides/slide1.xml", rich_slide_xml.sub("<p:spTree>", '<p:spTree><p:sp><p:spPr><a:prstGeom prst="ellipse"/></p:spPr></p:sp>'))
        write_entry(zip, "ppt/slides/_rels/slide1.xml.rels", rich_slide_relationships_xml)
        write_entry(zip, "ppt/charts/chart1.xml", xml)
      end
      html = Nokogiri::HTML.fragment(PptImporter.import(tmp, parent: nil, user: users(:one)).first.reload.description)
      assert_equal "ellipse", JSON.parse(html.at_css(".ppt-slide-text")["data-ppt-format"])["shape"]
      chart = JSON.parse(html.at_css(".ppt-slide-chart")["data-ppt-format"])["chart"]
      assert_equal 0, chart["min"]
      assert_equal 20, chart["max"]
      assert_equal [ [ "Sales", { "0" => "Q1" }, { "0" => "10" } ] ], chart["series"]
    end
  end

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

  test "orders numeric fallback slide names numerically" do
    with_archive("ppt/slides/slide10.xml" => slide_xml("Tenth"),
                 "ppt/slides/slide2.xml" => slide_xml("Second"),
                 "ppt/slides/slide1.xml" => slide_xml("First")) do |file|
      slides = import_file(file).drop(1)
      assert_equal [ "First", "Second", "Tenth" ], slides.map { |slide| Nokogiri::HTML.fragment(slide.reload.description).text.strip }
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
    entry.define_singleton_method(:name) { "oversized" }
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
      assert_equal "FirstSecond", html.css(".ppt-slide-layout > .ppt-slide-text p").last.text
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

  test "counts shared archive parts once without weakening actual size limits" do
    entries = { "ppt/presentation.xml" => presentation_xml,
                "ppt/_rels/presentation.xml.rels" => presentation_relationships_xml,
                "ppt/slides/slide1.xml" => slide_xml("One"),
                "ppt/slides/slide2.xml" => slide_xml("Two") }
    original = PptImporter::MAX_TOTAL_BYTES
    PptImporter.send(:remove_const, :MAX_TOTAL_BYTES)
    PptImporter.const_set(:MAX_TOTAL_BYTES, entries.values.sum(&:bytesize))
    with_archive(entries) { |file| assert_equal 3, import_file(file).size }
    importer = PptImporter.new(nil, parent: nil, user: users(:one), create_root: false, filename: nil)
    importer.instance_variable_set(:@read_bytes, 0)
    [ "a", "b" ].each_with_index do |name, index|
      entry = Object.new
      entry.define_singleton_method(:name) { name }
      entry.define_singleton_method(:get_input_stream) { |&block| block.call(StringIO.new("x" * entries.values.sum(&:bytesize))) }
      if index.zero?
        assert_equal entries.values.sum(&:bytesize), importer.send(:read_entry, entry).bytesize
      else
        assert_raises(PptImporter::InvalidArchive) { importer.send(:read_entry, entry) }
      end
    end
  ensure
    PptImporter.send(:remove_const, :MAX_TOTAL_BYTES)
    PptImporter.const_set(:MAX_TOTAL_BYTES, original)
  end

  test "renders only one supported compatibility branch including nested pictures and charts" do
    slide = rich_slide_xml.sub('<p:cSld>', '<p:cSld xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:new="urn:unsupported">')
    slide = slide.sub('<p:spTree>', '<p:spTree><mc:AlternateContent><mc:Choice Requires="new"><p:sp><p:txBody><a:p><a:r><a:t>Unsupported</a:t></a:r></a:p></p:txBody></p:sp></mc:Choice><mc:Fallback>')
                 .sub('</p:spTree>', '</mc:Fallback></mc:AlternateContent></p:spTree>')
    [ slide, slide.sub('<mc:Fallback>', '<mc:Choice Requires="p a c">').sub('</mc:Fallback>', '</mc:Choice><mc:Fallback><p:sp/></mc:Fallback>') ].each do |xml|
      with_archive("ppt/slides/slide1.xml" => xml,
                   "ppt/slides/_rels/slide1.xml.rels" => rich_slide_relationships_xml,
                   "ppt/media/image1.png" => SAMPLE_IMAGE, "ppt/charts/chart1.xml" => chart_xml) do |file|
        html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
        assert_equal 1, html.css(".ppt-slide-title").size
        assert_equal 1, html.css("img").size
        assert_equal 1, html.css(".ppt-slide-chart").size
        assert_includes html.text, "Grouped text"
        assert_not_includes html.text, "Unsupported"
      end
    end
    with_archive("ppt/slides/slide1.xml" => slide.sub(/<mc:Fallback>.*?<\/mc:Fallback>/m, "")) do |file|
      assert_empty Nokogiri::HTML.fragment(import_file(file).last.reload.description).css(".ppt-slide-element")
    end
  end

  test "renders master and layout decorations behind slide content with their own relationships" do
    entries = inheritance_entries
    entries["ppt/slideLayouts/layout.xml"] = rich_slide_xml
    entries["ppt/slideLayouts/_rels/layout.xml.rels"] = rich_slide_relationships_xml.sub('</Relationships>', '<Relationship Id="master" Type="x/slideMaster" Target="../slideMasters/master.xml"/></Relationships>')
    entries["ppt/media/image1.png"] = SAMPLE_IMAGE
    entries["ppt/charts/chart1.xml"] = chart_xml
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal [ "Master", "AlphaBeta", "RevenueSalesQ1:10", "Groupedtext", "Slide" ], html.css(".ppt-slide-layout > div").map { |n| n.text.gsub(/\s+/, "") }.reject(&:empty?)
      assert_equal 1, html.css("img").size
      assert_not_includes html.text, "Title & intro"
    end
    entries["ppt/slides/slide1.xml"] = entries["ppt/slides/slide1.xml"].sub('<p:sld ', '<p:sld showMasterSp="0" ')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal "Slide", html.text.strip
      assert_empty html.css("img")
    end
    entries["ppt/slides/slide1.xml"] = slide_xml("Slide")
    entries["ppt/slideLayouts/layout.xml"] = entries["ppt/slideLayouts/layout.xml"].sub('<p:sld ', '<p:sld showMasterSp="false" ')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_not_includes html.text, "Master"
      assert_equal 1, html.css("img").size
    end
  end

  test "cascades placeholder typography and honors explicit run overrides" do
    entries = inheritance_entries
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Slide", 'idx="4"')
      .sub('<a:p>', '<a:p><a:pPr><a:defRPr i="1"/></a:pPr>')
      .sub('</a:r></a:p>', '</a:r><a:r><a:rPr b="0" i="0" u="none" sz="1200"/><a:t>Override</a:t></a:r></a:p>')
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="title"')
      .sub('<a:p>', '<a:p><a:pPr><a:defRPr u="sng"><a:solidFill><a:srgbClr val="123456"/></a:solidFill></a:defRPr></a:pPr>')
    entries["ppt/slideMasters/master.xml"] = placeholder_slide("Master", 'type="title"')
      .sub('</p:sld>', '<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="2400" b="1"><a:latin typeface="Arial"/><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:defRPr></a:lvl1pPr></p:titleStyle></p:txStyles></p:sld>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      spans = html.css("p > span")
      assert_equal 2, spans.size
      assert_equal({ "fontSize" => 2.5, "font" => "Arial", "color" => "#123456" }, JSON.parse(spans.first["data-ppt-format"]))
      assert_equal "Slide", spans.first.text
      %w[strong em u].each { |tag| assert spans.first.at_css(tag), spans.first.to_html }
      assert_equal 1.25, JSON.parse(spans.last["data-ppt-format"])["fontSize"]
      assert_empty spans.last.css("strong, em, u")
    end
  end

  test "uses body list levels and presentation defaults without mutating inherited styles" do
    entries = inheritance_entries
    entries["ppt/presentation.xml"] = presentation_xml.sub(/<p:sldIdLst>.*?<\/p:sldIdLst>/m, "")
      .sub('</p:presentation>', '<p:defaultTextStyle><a:lvl2pPr algn="ctr" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:defRPr sz="1800"><a:latin typeface="Calibri"/></a:defRPr></a:lvl2pPr></p:defaultTextStyle></p:presentation>')
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Body", 'idx="4" type="body"').sub('<a:p>', '<a:p><a:pPr lvl="1"/>')
    entries["ppt/slides/slide2.xml"] = entries["ppt/slides/slide1.xml"].sub('<a:t>Body', '<a:t>Second')
    entries["ppt/slides/_rels/slide2.xml.rels"] = entries["ppt/slides/_rels/slide1.xml.rels"]
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="body"')
      .sub('<p:txBody>', '<p:txBody><a:lstStyle><a:lvl2pPr><a:defRPr b="1"/></a:lvl2pPr></a:lstStyle>')
    entries["ppt/slideMasters/master.xml"] = placeholder_slide("Master", 'type="body"')
      .sub('</p:sld>', '<p:txStyles><p:bodyStyle><a:lvl2pPr><a:defRPr sz="3000"/></a:lvl2pPr></p:bodyStyle></p:txStyles></p:sld>')
    with_archive(entries) do |file|
      slides = import_file(file).drop(1)
      assert_equal 2, slides.size
      slides.each do |slide|
        span = Nokogiri::HTML.fragment(slide.reload.description).at_css("p > span")
        assert_equal({ "fontSize" => 3.125, "font" => "Calibri" }, JSON.parse(span["data-ppt-format"]))
        assert span.at_css("strong")
        paragraph = span.parent
        assert_equal "ctr", JSON.parse(paragraph["data-ppt-format"])["align"]
      end
    end
  end

  test "persists rotations and flips on nested groups pictures shapes and frames" do
    xml = rich_slide_xml.gsub('<a:xfrm>', '<a:xfrm rot="5400000" flipH="1" flipV="false">')
      .gsub('<p:xfrm>', '<p:xfrm rot="-5400000" flipV="true">')
    with_archive("ppt/slides/slide1.xml" => xml,
                 "ppt/slides/_rels/slide1.xml.rels" => rich_slide_relationships_xml,
                 "ppt/media/image1.png" => SAMPLE_IMAGE, "ppt/charts/chart1.xml" => chart_xml) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      %w[.ppt-slide-title .ppt-slide-image .ppt-slide-group].each do |selector|
        data = JSON.parse(html.at_css(selector)["data-ppt-format"])
        assert_equal [ 90, true, false ], data.values_at("rotation", "flipH", "flipV"), selector
      end
      html.css(".ppt-slide-graphic").each do |frame|
        assert_equal [ 270, true ], JSON.parse(frame["data-ppt-format"]).values_at("rotation", "flipV")
      end
    end
  end

  test "resolves theme colors and slide color map overrides in persisted output" do
    entries = inheritance_entries
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:clrScheme name="Test"><a:accent1><a:srgbClr val="204060"/></a:accent1><a:accent2><a:srgbClr val="804020"/></a:accent2><a:dk1><a:sysClr val="windowText" lastClr="123456"/></a:dk1></a:clrScheme></a:themeElements></a:theme>'
    entries["ppt/slideMasters/master.xml"] = entries["ppt/slideMasters/master.xml"].sub('</p:sld>', '<p:clrMap tx1="dk1" accent1="accent2"/></p:sld>')
    entries["ppt/slides/slide1.xml"] = slide_xml("Theme")
      .sub('<p:sp>', '<p:sp><p:spPr><a:solidFill><a:schemeClr val="accent1"><a:tint val="50000"/></a:schemeClr></a:solidFill><a:ln w="12700"><a:solidFill><a:schemeClr val="accent1"><a:shade val="50000"/></a:schemeClr></a:solidFill></a:ln></p:spPr>')
      .sub('<a:r>', '<a:r><a:rPr><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:rPr>')
      .sub('</p:sld>', '<p:clrMapOvr><a:overrideClrMapping accent1="accent1" tx1="dk1"/></p:clrMapOvr></p:sld>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.css(".ppt-slide-text").last["data-ppt-format"])
      assert_equal [ "#90A0B0", "#102030" ], data.values_at("fill", "stroke")
      assert_equal "#123456", JSON.parse(html.css("span[data-ppt-format]").last["data-ppt-format"])["color"]
    end
  end

  test "cascades paragraph defaults and respects local spacing and bullet cancellation" do
    entries = inheritance_entries
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Inherited", 'idx="4" type="body"')
      .sub('</p:txBody>', '<a:p><a:pPr algn="r"><a:buNone/><a:spcAft><a:spcPts val="0"/></a:spcAft><a:lnSpc><a:spcPts val="2400"/></a:lnSpc></a:pPr><a:r><a:t>Local</a:t></a:r></a:p></p:txBody>')
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="body"')
      .sub('<p:txBody>', '<p:txBody><a:lstStyle><a:lvl1pPr algn="ctr"><a:spcBef><a:spcPts val="960"/></a:spcBef></a:lvl1pPr></a:lstStyle>')
    entries["ppt/slideMasters/master.xml"] = placeholder_slide("Master", 'type="body"')
      .sub('</p:sld>', '<p:txStyles><p:bodyStyle><a:lvl1pPr algn="l"><a:buChar char="•"/><a:spcAft><a:spcPct val="50000"/></a:spcAft><a:lnSpc><a:spcPct val="120000"/></a:lnSpc></a:lvl1pPr></p:bodyStyle></p:txStyles></p:sld>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      paragraphs = html.css('p')
      assert_equal [ "• Inherited", "Local" ], paragraphs.map(&:text)
      assert_equal({ "align" => "ctr", "spaceBefore" => 1.0, "spaceAfterEm" => 0.5, "lineHeight" => 1.2 }, JSON.parse(paragraphs.first["data-ppt-format"]))
      assert_equal({ "align" => "r", "spaceBefore" => 1.0, "spaceAfter" => 0.0, "lineHeightPoints" => 2.5 }, JSON.parse(paragraphs.last["data-ppt-format"]))
    end
  end

  test "persists inherited list indentation with hanging and local zero overrides" do
    entries = inheritance_entries
    paragraphs = [ "", '<a:pPr lvl="1"/>', '<a:pPr lvl="1" marL="0" indent="0"/>' ].map do |properties|
      "<a:p>#{properties}<a:r><a:t>Item</a:t></a:r></a:p>"
    end.join
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Slide", 'idx="4" type="body"')
      .sub('<a:p><a:r><a:t>Slide</a:t></a:r></a:p>', paragraphs)
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="body"')
      .sub('<p:txBody>', '<p:txBody><a:lstStyle><a:lvl2pPr marL="731520"/></a:lstStyle>')
    entries["ppt/slideMasters/master.xml"] = placeholder_slide("Master", 'type="body"')
      .sub('</p:sld>', '<p:txStyles><p:bodyStyle><a:lvl1pPr marL="365760" indent="-182880"><a:buChar char="•"/></a:lvl1pPr><a:lvl2pPr marL="548640" indent="-182880"><a:buChar char="•"/></a:lvl2pPr></p:bodyStyle></p:txStyles></p:sld>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal [ "• Item" ] * 3, html.css("p").map(&:text)
      assert_equal [ [ 3.0, -1.5 ], [ 6.0, -1.5 ], [ 0.0, 0.0 ] ], html.css("p").map { |p| JSON.parse(p["data-ppt-format"]).values_at("marginLeft", "textIndent") }
    end
  end

  test "validates paragraph indentation before serializing responsive lengths" do
    importer = Object.new.extend(Collavre::PptParagraphs)
    importer.instance_variable_set(:@slide_size, [ 1000, 750 ])
    [ [ nil, nil ], [ "bad", "NaN" ], [ "-1", "1001" ], [ "1.5", "-1001" ], [ "1001", "1e2" ] ].each do |margin, indent|
      properties = Nokogiri::XML('<p/>').root
      properties["marL"] = margin if margin
      properties["indent"] = indent if indent
      assert_empty importer.send(:paragraph_indentation, properties)
    end
    assert_empty importer.send(:paragraph_indentation, nil)
    properties = Nokogiri::XML('<p marL="+1000" indent="1000"/>').root
    assert_equal({ marginLeft: 100.0, textIndent: 100.0 }, importer.send(:paragraph_indentation, properties))
    properties["indent"] = "-1000"
    assert_equal(-100.0, importer.send(:paragraph_indentation, properties)[:textIndent])
  end

  test "inherits backgrounds in slide layout master order and resolves theme fill references" do
    entries = inheritance_entries
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:clrScheme><a:accent1><a:srgbClr val="204060"/></a:accent1></a:clrScheme><a:fmtScheme><a:fillStyleLst><a:solidFill><a:srgbClr val="123456"/></a:solidFill></a:fillStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"><a:shade val="50000"/></a:schemeClr></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>'
    cases = [
      [ "ppt/slideMasters/master.xml", '<p:bgPr><a:solidFill><a:srgbClr val="102030"/></a:solidFill></p:bgPr>', "#102030" ],
      [ "ppt/slideLayouts/layout.xml", '<p:bgRef idx="1001"><a:schemeClr val="accent1"><a:tint val="50000"/></a:schemeClr></p:bgRef>', "#485058" ],
      [ "ppt/slides/slide1.xml", '<p:bgRef idx="1"><a:schemeClr val="accent1"/></p:bgRef>', "#123456" ],
      [ "ppt/slides/slide1.xml", '<p:bgPr><a:solidFill><a:srgbClr val="ABCDEF"/></a:solidFill></p:bgPr>', "#ABCDEF" ],
      [ "ppt/slides/slide1.xml", '<p:bgPr><a:noFill/></p:bgPr>', "#ffffff" ]
    ]
    cases.each do |path, background, expected|
      entries[path] = slide_xml("Background").sub('<p:cSld>', "<p:cSld><p:bg>#{background}</p:bg>")
      with_archive(entries) do |file|
        html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
        assert_equal expected, JSON.parse(html.at_css(".ppt-slide")["data-ppt-format"])["fill"]
      end
    end
  end

  test "preserves inherited numbering starts levels restarts and independent text bodies" do
    entries = inheritance_entries
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Template", 'type="body" idx="1"').sub("<p:txBody>", '<p:txBody><a:lstStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="5"/></a:lvl1pPr><a:lvl2pPr><a:buAutoNum type="alphaLcParenR"/></a:lvl2pPr></a:lstStyle>')
    paragraphs = [ "", '<a:pPr lvl="1"/>', '<a:pPr lvl="1"/>', "", '<a:pPr><a:buAutoNum type="romanUcParenBoth" startAt="4"/></a:pPr>', '<a:pPr><a:buAutoNum type="romanUcParenBoth"/></a:pPr>', '<a:pPr><a:buNone/></a:pPr>', "", '<a:pPr><a:buChar char="•"/></a:pPr>', "" ].map do |properties|
      "<a:p>#{properties}<a:r><a:t>Item</a:t></a:r></a:p>"
    end.join
    xml = placeholder_slide("Slide", 'type="body" idx="1"').sub('<a:p><a:r><a:t>Slide</a:t></a:r></a:p>', paragraphs)
    entries["ppt/slides/slide1.xml"] = xml
    with_archive(entries) do |tmp|
      html = Nokogiri::HTML.fragment(PptImporter.import(tmp, parent: nil, user: users(:one)).first.reload.description)
      assert_equal [ "5. Item", "a) Item", "b) Item", "6. Item", "(IV) Item", "(V) Item", "Item", "5. Item", "• Item", "5. Item" ], html.css('.ppt-slide-text').last.css('p').map(&:text)
    end
  end

  test "persists unequal table geometry and isolates numbering in table cells" do
    xml = rich_slide_xml.sub('<a:tbl>', '<a:tbl><a:tblGrid><a:gridCol w="100"/><a:gridCol w="300"/></a:tblGrid>')
    xml = xml.sub('<a:tr>', '<a:tr h="100">').sub('</a:tbl>', '<a:tr h="300"><a:tc gridSpan="2"><a:txBody><a:p><a:r><a:t>Wide</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>')
    xml = xml.gsub('<a:p>', '<a:p><a:pPr><a:buAutoNum type="arabicPeriod" startAt="3"/></a:pPr>')
    with_archive("ppt/slides/slide1.xml" => xml) do |tmp|
      html = Nokogiri::HTML.fragment(PptImporter.import(tmp, parent: nil, user: users(:one)).first.reload.description)
      table = html.at_css('.ppt-slide-table')
      assert_equal({ "columns" => [ 25.0, 75.0 ], "rows" => [ 25.0, 75.0 ] }, JSON.parse(table['data-ppt-format']))
      assert_equal [ "3. Alpha", "3. Beta", "3. Wide" ], table.css('td').map { |cell| cell.text.strip }
      assert_equal '2', table.css('td').last['colspan']
    end
  end

  test "persists placeholder shape cascade and explicit visual overrides" do
    entries = inheritance_entries
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Slide", 'idx="4"')
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="title"')
      .sub("<p:txBody>", '<p:spPr><a:solidFill><a:srgbClr val="AABBCC"/></a:solidFill><a:ln w="24384"/></p:spPr><p:txBody>')
    entries["ppt/slideMasters/master.xml"] = placeholder_slide("Master", 'type="title"')
      .sub("<p:txBody>", '<p:spPr><a:solidFill><a:srgbClr val="112233"/></a:solidFill><a:ln w="12192"><a:solidFill><a:srgbClr val="445566"/></a:solidFill></a:ln><a:prstGeom prst="ellipse"/></p:spPr><p:txBody>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      shapes = html.css(".ppt-slide-element")
      assert_equal 1, shapes.size
      assert_equal({ "fill" => "#AABBCC", "stroke" => "#445566", "strokeWidth" => 0.2, "shape" => "ellipse" }, JSON.parse(shapes.first["data-ppt-format"]))
    end
    entries["ppt/slides/slide1.xml"] = entries["ppt/slides/slide1.xml"].sub("<p:txBody>", '<p:spPr><a:noFill/><a:ln w="0"><a:noFill/></a:ln><a:prstGeom prst="roundRect"/></p:spPr><p:txBody>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal({ "strokeWidth" => 0.0, "shape" => "roundRect" }, JSON.parse(html.at_css(".ppt-slide-element")["data-ppt-format"]))
    end
  end

  test "resolves inherited major and minor theme fonts before persistence" do
    entries = inheritance_entries
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Slide", 'idx="4"')
      .sub('</a:r></a:p>', '</a:r><a:r><a:rPr><a:latin typeface="+mn-lt"/></a:rPr><a:t>Minor</a:t></a:r><a:r><a:rPr><a:latin typeface="Georgia"/></a:rPr><a:t>Local</a:t></a:r></a:p>')
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="title"')
      .sub('<a:p>', '<a:p><a:pPr><a:defRPr><a:latin typeface="+mj-lt"/></a:defRPr></a:pPr>')
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:fontScheme><a:majorFont><a:latin typeface="Cambria"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme></a:themeElements></a:theme>'
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal [ "Cambria", "Aptos", "Georgia" ], html.css("p > span").to_a.last(3).map { |span| JSON.parse(span["data-ppt-format"])["font"] }
    end
  end


  test "persists inherited text body attributes and explicit local zero overrides" do
    entries = inheritance_entries
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Slide", 'idx="4"').sub("<p:txBody>", '<p:txBody><a:bodyPr/>')
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="title"')
      .sub("<p:txBody>", '<p:txBody><a:bodyPr anchor="ctr" lIns="243840"/>')
    entries["ppt/slideMasters/master.xml"] = placeholder_slide("Master", 'type="title"')
      .sub("<p:txBody>", '<p:txBody><a:bodyPr anchor="b" lIns="121920" tIns="365760" rIns="487680" bIns="609600"/>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.at_css(".ppt-slide-element")["data-ppt-format"])
      assert_equal "ctr", data["anchor"]
      assert_equal [ 2, 3, 4, 5 ], data["insets"]
    end
    entries["ppt/slides/slide1.xml"] = entries["ppt/slides/slide1.xml"].sub('<a:bodyPr/>', '<a:bodyPr anchor="t" lIns="0" bIns="0"/>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.at_css(".ppt-slide-element")["data-ppt-format"])
      assert_equal "t", data["anchor"]
      assert_equal [ 0, 3, 4, 0 ], data["insets"]
    end
  end

  test "nearer paragraph and run fills replace inherited solid colors after persistence" do
    entries = inheritance_entries
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="title"')
      .sub("<a:p>", '<a:p><a:pPr><a:defRPr><a:solidFill><a:srgbClr val="112233"/></a:solidFill></a:defRPr></a:pPr>')
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Slide", 'idx="4"')
      .sub('<a:p><a:r><a:t>Slide</a:t></a:r></a:p>', '<a:p><a:pPr><a:defRPr><a:noFill/></a:defRPr></a:pPr><a:r><a:t>Hidden</a:t></a:r><a:r><a:rPr><a:solidFill><a:srgbClr val="445566"/></a:solidFill></a:rPr><a:t>Visible</a:t></a:r><a:r><a:rPr><a:gradFill/></a:rPr><a:t>Gradient</a:t></a:r></a:p>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = html.css("p > span").map { |span| JSON.parse(span["data-ppt-format"]) }
      assert_equal [ { "noFill" => true }, { "color" => "#445566" }, {} ], data.last(3)
      assert_includes html.text, "Hidden"
    end
  end

  test "persists safe run hyperlinks using each source parts relationships" do
    entries = inheritance_entries
    entries["ppt/slides/slide1.xml"] = linked_slide("Slide")
    entries["ppt/slideLayouts/layout.xml"] = linked_slide("Layout")
    entries["ppt/slides/_rels/slide1.xml.rels"] = link_relationships(entries["ppt/slides/_rels/slide1.xml.rels"], "https://example.com/?a=1&amp;b=2")
    entries["ppt/slideLayouts/_rels/layout.xml.rels"] = link_relationships(entries["ppt/slideLayouts/_rels/layout.xml.rels"], "mailto:team@example.com")
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal [ "mailto:team@example.com", "https://example.com/?a=1&b=2" ], html.css("a").map { |link| link["href"] }
      assert_equal [ "Layout", "Slide" ], html.css("a span").map(&:text)
    end
  end

  test "drops unsafe missing and non hyperlink targets while preserving labels" do
    [ "javascript:alert(1)", "data:text/html,hello", "file:///tmp/file", "//example.com", "https://", "https://example.com/ bad", "https://example.com/%ZZ" ].each do |target|
      entries = { "ppt/slides/slide1.xml" => linked_slide("Label"),
                  "ppt/slides/_rels/slide1.xml.rels" => link_relationships(relationships_xml("image", "../image.png"), target) }
      with_archive(entries) do |file|
        html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
        assert_empty html.css("a"), target
        assert_includes html.text, "Label"
      end
    end
  end

  test "persists picture crop offsets alongside frame geometry" do
    entries = { "ppt/slides/slide1.xml" => rich_slide_xml.sub("</p:blipFill>", '<a:srcRect l="25000" r="25000" t="10000" b="20000"/></p:blipFill>'),
                "ppt/slides/_rels/slide1.xml.rels" => rich_slide_relationships_xml,
                "ppt/media/image1.png" => SAMPLE_IMAGE }
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      format = JSON.parse(html.at_css(".ppt-slide-image")["data-ppt-format"])
      assert_equal [ 0.25, 0.1, 0.25, 0.2 ], format["crop"]
      assert_equal [ 50, 5, 45, 40 ], format.values_at("x", "y", "w", "h")
      assert html.at_css(".ppt-slide-image img")["src"].start_with?("/public-assets/blobs/")
    end
  end

  def linked_slide(text)
    slide_xml(text).sub('<p:sld ', '<p:sld xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ')
      .sub("<a:r>", '<a:r><a:rPr><a:hlinkClick r:id="link"/></a:rPr>')
  end

  def link_relationships(xml, target)
    xml.sub("</Relationships>", %(<Relationship Id="link" Type="x/hyperlink" TargetMode="External" Target="#{target}"/></Relationships>))
  end

  test "persists independent fill stroke and text alpha through sanitization" do
    slide = slide_xml("Translucent")
      .sub('<p:sp>', '<p:sp><p:spPr><a:solidFill><a:srgbClr val="FF0000"><a:alpha val="50000"/></a:srgbClr></a:solidFill><a:ln w="12700"><a:solidFill><a:srgbClr val="00FF00"><a:alphaOff val="-75000"/></a:srgbClr></a:solidFill></a:ln></p:spPr>')
      .sub('<a:r>', '<a:r><a:rPr><a:solidFill><a:srgbClr val="0000FF"><a:alphaMod val="0"/></a:srgbClr></a:solidFill></a:rPr>')
    with_archive("ppt/slides/slide1.xml" => slide) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.at_css(".ppt-slide-text")["data-ppt-format"])
      assert_equal [ "#FF000080", "#00FF0040" ], data.values_at("fill", "stroke")
      assert_equal "#0000FF00", JSON.parse(html.at_css("span[data-ppt-format]")["data-ppt-format"])["color"]
    end
  end

  test "persists theme shape references with placeholder colors and explicit overrides" do
    entries = inheritance_entries
    entries["ppt/slideMasters/master.xml"] = placeholder_slide("Master", 'type="title"')
    entries["ppt/slides/slide1.xml"] = placeholder_slide("Slide", 'idx="4"')
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="title"')
      .sub("<p:txBody>", '<p:style><a:fillRef idx="1"><a:schemeClr val="accent1"><a:alpha val="50000"/></a:schemeClr></a:fillRef><a:lnRef idx="1"><a:srgbClr val="804020"/></a:lnRef></p:style><p:txBody>')
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:clrScheme><a:accent1><a:srgbClr val="204060"/></a:accent1></a:clrScheme><a:fmtScheme><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"><a:shade val="50000"/><a:alphaMod val="50000"/></a:schemeClr></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="24384"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst></a:fmtScheme></a:themeElements></a:theme>'
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.at_css(".ppt-slide-element")["data-ppt-format"])
      assert_equal [ "#10203040", "#804020", 0.2 ], data.values_at("fill", "stroke", "strokeWidth")
    end
    entries["ppt/slides/slide1.xml"] = entries["ppt/slides/slide1.xml"].sub("<p:txBody>", '<p:spPr><a:noFill/><a:ln w="12192"/></p:spPr><p:txBody>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.at_css(".ppt-slide-element")["data-ppt-format"])
      assert_nil data["fill"]
      assert_equal [ "#804020", 0.1 ], data.values_at("stroke", "strokeWidth")
    end
  end

  test "ignores section slide IDs and extension lookalikes when ordering slides" do
    sections = '<p:extLst><p:ext uri="sections"><p14:sectionLst xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main"><p14:section><p14:sldIdLst>' + '<p14:sldId id="256"/>' * (PptImporter::MAX_SLIDES + 1) + '</p14:sldIdLst></p14:section></p14:sectionLst><p:sldIdLst><p:sldId/></p:sldIdLst></p:ext></p:extLst>'
    entries = {
      "ppt/presentation.xml" => presentation_xml.sub('</p:presentation>', sections + '</p:presentation>'),
      "ppt/_rels/presentation.xml.rels" => presentation_relationships_xml,
      "ppt/slides/slide1.xml" => slide_xml("First"),
      "ppt/slides/slide2.xml" => slide_xml("Second")
    }
    with_archive(entries) do |file|
      slides = import_file(file).drop(1)
      assert_equal [ "Second", "First" ], slides.map { |slide| Nokogiri::HTML.fragment(slide.reload.description).at_css("p").text }
    end
    entries["ppt/presentation.xml"] = entries["ppt/presentation.xml"].sub('r:id="rId2"', '')
    with_archive(entries) do |file|
      assert_no_difference("Creative.count") { assert_raises(PptImporter::InvalidArchive) { import_file(file) } }
    end
  end

  test "persists East Asian and complex script run typefaces" do
    entries = { "ppt/slides/slide1.xml" => slide_xml("Text") }
    [ [ "한국어", "ea", "맑은 고딕" ], [ "中文", "ea", "Noto Sans CJK" ], [ "日本語", "ea", "Yu Gothic" ], [ "مرحبا", "cs", "Noto Naskh Arabic" ] ].each do |text, script, font|
      entries["ppt/slides/slide1.xml"] = slide_xml(text).sub('<a:r>', %(<a:r><a:rPr><a:latin typeface="Arial"/><a:#{script} typeface="#{font}"/></a:rPr>))
      with_archive(entries) do |file|
        span = Nokogiri::HTML.fragment(import_file(file).last.reload.description).at_css("p > span")
        assert_equal font, JSON.parse(span["data-ppt-format"])["font"]
        assert_equal text, span.text
      end
    end
  end

  test "persists inherited script theme fonts and direct run overrides" do
    entries = inheritance_entries
    entries["ppt/slides/slide1.xml"] = placeholder_slide("한글", 'idx="4"')
      .sub('</a:r></a:p>', '</a:r><a:r><a:rPr><a:cs typeface="+mn-cs"/></a:rPr><a:t>مرحبا</a:t></a:r><a:r><a:rPr><a:ea typeface="Yu Gothic"/></a:rPr><a:t>日本語</a:t></a:r></a:p>')
    entries["ppt/slideLayouts/layout.xml"] = placeholder_slide("Layout", 'idx="4" type="title"')
      .sub('<a:p>', '<a:p><a:pPr><a:defRPr><a:latin typeface="Arial"/><a:ea typeface="+mj-ea"/></a:defRPr></a:pPr>')
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:fontScheme><a:majorFont><a:ea typeface="맑은 고딕"/></a:majorFont><a:minorFont><a:cs typeface="Amiri"/></a:minorFont></a:fontScheme></a:themeElements></a:theme>'
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      assert_equal [ "맑은 고딕", "Amiri", "Yu Gothic" ], html.css("p > span").to_a.last(3).map { |span| JSON.parse(span["data-ppt-format"])["font"] }
    end
  end

  test "bounds repeated relationship slides before creating records or blobs" do
    entries = {
      "ppt/presentation.xml" => '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst>' + '<p:sldId r:id="rId1"/>' * (PptImporter::MAX_SLIDES + 1) + '</p:sldIdLst></p:presentation>',
      "ppt/_rels/presentation.xml.rels" => relationships_xml("slide", "slides/slide1.xml"),
      "ppt/slides/slide1.xml" => rich_slide_xml
    }
    with_archive(entries) do |file|
      Creative::RealtimeBroadcastable.stub(:broadcast_batch_created, ->(*) { flunk "Unexpected broadcast" }) do
        assert_no_difference([ "Creative.count", "ActiveStorage::Blob.count" ]) do
          Creative.stub(:create!, ->(*) { flunk "Must reject before creating any Creative" }) do
            assert_raises(PptImporter::InvalidArchive) { import_file(file) }
          end
        end
      end
    end
  end

  test "bounds filename fallback slide count before creating a root" do
    entries = (1..PptImporter::MAX_SLIDES + 1).to_h { |i| [ "ppt/slides/slide#{i}.xml", slide_xml("Slide") ] }
    with_archive(entries) do |file|
      assert_no_difference("Creative.count") { assert_raises(PptImporter::InvalidArchive) { import_file(file) } }
    end
  end

  test "accepts the exact slide limit in relationship order without deduplicating" do
    original = PptImporter::MAX_SLIDES
    PptImporter.send(:remove_const, :MAX_SLIDES)
    PptImporter.const_set(:MAX_SLIDES, 2)
    entries = {
      "ppt/presentation.xml" => '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId r:id="rId1"/><p:sldId r:id="rId1"/></p:sldIdLst></p:presentation>',
      "ppt/_rels/presentation.xml.rels" => relationships_xml("slide", "slides/slide1.xml"),
      "ppt/slides/slide1.xml" => slide_xml("Repeated")
    }
    with_archive(entries) do |file|
      assert_equal 3, import_file(file).size
    end
    entries.delete("ppt/presentation.xml")
    entries["ppt/slides/slide2.xml"] = slide_xml("Second")
    with_archive(entries) { |file| assert_equal 3, import_file(file).size }
  ensure
    PptImporter.send(:remove_const, :MAX_SLIDES)
    PptImporter.const_set(:MAX_SLIDES, original)
  end

  test "persists local and theme shape gradients and patterns with explicit overrides" do
    gradient = '<a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="204060"><a:alpha val="50000"/></a:srgbClr></a:gs><a:gs pos="100000"><a:srgbClr val="FFFFFF"/></a:gs></a:gsLst><a:lin ang="2700000" scaled="1"/></a:gradFill>'
    pattern = '<a:pattFill prst="diagCross"><a:fgClr><a:srgbClr val="112233"/></a:fgClr><a:bgClr><a:srgbClr val="FFFFFF"/></a:bgClr></a:pattFill>'
    entries = inheritance_entries
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:fmtScheme><a:fillStyleLst>' + gradient + '</a:fillStyleLst></a:fmtScheme></a:themeElements></a:theme>'
    [ [ "", "linear" ], [ pattern, "pattern" ], [ '<a:noFill/>', nil ] ].each do |fill, type|
      entries["ppt/slides/slide1.xml"] = slide_xml("Shape").sub('<p:txBody>', '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="200000" cy="100000"/></a:xfrm><a:prstGeom prst="triangle"/>' + fill + '</p:spPr><p:style><a:fillRef idx="1"/></p:style><p:txBody>')
      with_archive(entries) do |file|
        html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
        data = JSON.parse(html.css('.ppt-slide-text').last['data-ppt-format'])
        if type
          assert_equal type, data.fetch('background')['type']
          assert_equal 'triangle', data['shape']
          if type == 'linear'
            assert_in_delta 26.565, data['background']['angle'], 0.001
            assert_equal '#20406080', data['background']['stops'].first.last
          end
        else
          assert_nil data['background']
          assert_nil data['fill']
        end
      end
    end
    html = import_connector_fixture(slide_xml("Local").sub('<p:txBody>', '<p:spPr>' + gradient + '</p:spPr><p:txBody>'))
    assert_equal 'linear', JSON.parse(html.at_css('.ppt-slide-text')['data-ppt-format']).fetch('background')['type']
  end

  test "persists shape pictures from slide layout and theme relationships" do
    fill = '<a:blipFill data-source-part="evil"><a:blip r:embed="rId1"/><a:srcRect l="10000" r="20000"/></a:blipFill>'
    %w[slide layout theme].each do |owner|
      entries = inheritance_entries
      entries['ppt/media/fill.png'] = SAMPLE_IMAGE
      entries['ppt/slides/slide1.xml'] = placeholder_slide('Shape', 'idx="1"')
      part, rels = case owner
      when 'slide' then [ 'ppt/slides/slide1.xml', 'ppt/slides/_rels/slide1.xml.rels' ]
      when 'layout' then [ 'ppt/slideLayouts/layout.xml', 'ppt/slideLayouts/_rels/layout.xml.rels' ]
      else [ 'ppt/theme/theme1.xml', 'ppt/theme/_rels/theme1.xml.rels' ]
      end
      entries[part] = placeholder_slide('Shape', 'idx="1"').sub('<p:txBody>', '<p:spPr>' + fill + '</p:spPr><p:txBody>')
      if owner == 'theme'
        entries['ppt/slideMasters/_rels/master.xml.rels'] = relationships_xml('theme', '../theme/theme1.xml')
        entries[part] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><a:themeElements><a:fmtScheme><a:fillStyleLst>' + fill + '</a:fillStyleLst></a:fmtScheme></a:themeElements></a:theme>'
        entries['ppt/slides/slide1.xml'] = slide_xml('Shape').sub('<p:txBody>', '<p:style><a:fillRef idx="1"/></p:style><p:txBody>')
      end
      # Keep the inheritance relationship while reusing the same ID in each part.
      entries[rels] ||= '<Relationships></Relationships>'
      entries[rels] = entries[rels].sub('Id="rId1"', 'Id="inherit"').sub('</Relationships>', '<Relationship Id="rId1" Type="x/image" Target="../media/fill.png"/></Relationships>')
      with_archive(entries) do |file|
        creative = import_file(file).last.reload
        html = Nokogiri::HTML.fragment(creative.description)
        image = html.at_css('.ppt-slide-text > .ppt-shape-fill img')
        assert image, owner
        assert_equal [ 0.1, 0, 0.2, 0 ], JSON.parse(image.parent['data-ppt-format'])['crop']
        assert_equal SAMPLE_IMAGE, creative.files.blobs.find_by!(filename: 'fill.png').download
      end
    end
  end

  private

  test "persists shape font references beneath explicit text formatting" do
    entries = inheritance_entries
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:fontScheme><a:majorFont><a:latin typeface="Cambria"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme><a:clrScheme><a:accent1><a:srgbClr val="204060"/></a:accent1></a:clrScheme></a:themeElements></a:theme>'
    entries["ppt/slides/slide1.xml"] = slide_xml("Theme text").sub("<p:txBody>", '<p:style><a:fontRef idx="major"><a:schemeClr val="accent1"><a:alpha val="50000"/></a:schemeClr></a:fontRef></p:style><p:txBody>')
    [ [ "", "Cambria", "#20406080" ], [ '<a:rPr><a:latin typeface="Arial"/><a:solidFill><a:srgbClr val="ABCDEF"/></a:solidFill></a:rPr>', "Arial", "#ABCDEF" ] ].each do |properties, font, color|
      original = entries["ppt/slides/slide1.xml"]
      entries["ppt/slides/slide1.xml"] = original.sub("<a:r>", "<a:r>#{properties}")
      with_archive(entries) do |file|
        html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
        data = JSON.parse(html.css('.ppt-slide-text').last.at_css('span')["data-ppt-format"])
        assert_equal [ font, color ], data.values_at("font", "color")
      end
      entries["ppt/slides/slide1.xml"] = original
    end
  end

  test "persists inherited and theme non solid backgrounds including attached pictures" do
    entries = inheritance_entries
    gradient = '<a:gradFill><a:gsLst><a:gs pos="100000"><a:srgbClr val="FFFFFF"/></a:gs><a:gs pos="0"><a:schemeClr val="phClr"><a:alphaMod val="50000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000"/></a:gradFill>'
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:fmtScheme><a:bgFillStyleLst>' + gradient + '</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>'
    entries["ppt/slideLayouts/layout.xml"] = slide_xml("Layout").sub('<p:cSld>', '<p:cSld><p:bg><p:bgRef idx="1001"><a:srgbClr val="204060"><a:alpha val="50000"/></a:srgbClr></p:bgRef></p:bg>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.at_css('.ppt-slide')["data-ppt-format"])["background"]
      assert data
      assert_equal [ "linear", 90, [ [ 0, "#20406040" ], [ 100, "#FFFFFF" ] ] ], data.values_at("type", "angle", "stops")
    end
    entries["ppt/slides/slide1.xml"] = slide_xml("Slide").sub('<p:cSld>', '<p:cSld><p:bg><p:bgPr><a:pattFill prst="diagCross"><a:fgClr><a:srgbClr val="112233"/></a:fgClr><a:bgClr><a:srgbClr val="FFFFFF"/></a:bgClr></a:pattFill></p:bgPr></p:bg>')
    with_archive(entries) do |file|
      html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
      data = JSON.parse(html.at_css('.ppt-slide')["data-ppt-format"])["background"]
      assert data
      assert_equal [ "pattern", "diagCross", "#112233", "#FFFFFF" ], data.values_at("type", "preset", "foreground", "background")
    end
    entries["ppt/slides/slide1.xml"] = slide_xml("Slide")
    entries["ppt/slideLayouts/layout.xml"] = slide_xml("Layout").sub('<p:cSld>', '<p:cSld><p:bg><p:bgPr><a:blipFill><a:blip r:embed="background"/><a:srcRect l="10000" r="20000"/><a:stretch><a:fillRect/></a:stretch></a:blipFill></p:bgPr></p:bg>')
    entries["ppt/slideLayouts/_rels/layout.xml.rels"] = entries["ppt/slideLayouts/_rels/layout.xml.rels"].sub('</Relationships>', '<Relationship Id="background" Type="x/image" Target="../media/background.png"/></Relationships>')
    entries["ppt/media/background.png"] = SAMPLE_IMAGE
    with_archive(entries) do |file|
      creative = import_file(file).last.reload
      html = Nokogiri::HTML.fragment(creative.description)
      image = html.at_css('.ppt-slide > .ppt-slide-background img')
      assert image
      assert_match %r{\A/public-assets/blobs/}, image['src']
      assert_equal [ 0.1, 0, 0.2, 0 ], JSON.parse(image.parent['data-ppt-format'])['crop']
      assert_equal SAMPLE_IMAGE, creative.files.blobs.find_by!(filename: 'background.png').download
      assert_equal 'ppt-slide-layout', image.parent.next_element['class']
    end
  end

  test "resolves theme background images from their owning part and rejects unsafe relationships" do
    entries = inheritance_entries
    entries["ppt/slideMasters/_rels/master.xml.rels"] = relationships_xml("theme", "../theme/theme1.xml")
    entries["ppt/theme/theme1.xml"] = '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><a:themeElements><a:fmtScheme><a:bgFillStyleLst><a:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></a:blipFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>'
    entries["ppt/slides/slide1.xml"] = slide_xml("Slide").sub('<p:cSld>', '<p:cSld><p:bg><p:bgRef idx="1001"/></p:bg>')
    entries["ppt/media/theme.png"] = SAMPLE_IMAGE
    relation = relationships_xml("image", "../media/theme.png")
    [ [ relation, 1 ], [ relation.sub('Type="http', 'TargetMode="External" Type="http'), 0 ], [ relation.sub('/image"', '/hyperlink"'), 0 ], [ relation.sub('theme.png', 'missing.png'), 0 ], [ '<Relationships/>', 0 ] ].each do |rels, count|
      entries["ppt/theme/_rels/theme1.xml.rels"] = rels
      with_archive(entries) do |file|
        html = Nokogiri::HTML.fragment(import_file(file).last.reload.description)
        assert_equal count, html.css('.ppt-slide-background img').size
      end
    end
  end

  def inheritance_entries
    { "ppt/slides/slide1.xml" => slide_xml("Slide"),
      "ppt/slides/_rels/slide1.xml.rels" => relationships_xml("slideLayout", "../slideLayouts/layout.xml"),
      "ppt/slideLayouts/layout.xml" => slide_xml("Layout"),
      "ppt/slideLayouts/_rels/layout.xml.rels" => relationships_xml("slideMaster", "../slideMasters/master.xml"),
      "ppt/slideMasters/master.xml" => slide_xml("Master") }
  end

  def placeholder_slide(text, attributes)
    slide_xml(text).sub("<p:txBody>", "<p:nvSpPr><p:nvPr><p:ph #{attributes}/></p:nvPr></p:nvSpPr><p:txBody>")
  end

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

# Real commits are essential here: transactional fixtures defer after_commit.
class PptImporterCommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "keeps uploaded bytes when a creative after_commit callback raises" do
    marker = "PPT commit failure regression"
    callback = -> { raise IOError, "enqueue failed" if description.include?(marker) }
    Creative.set_callback(:commit, :after, callback)
    blobs = []
    original = ActiveStorage::Blob.method(:build_after_unfurling)
    track = ->(**args) { original.call(**args).tap { |blob| blobs << blob } }
    Tempfile.create([ "commit", ".pptx" ]) do |file|
      Zip::OutputStream.open(file.path) do |zip|
        zip.put_next_entry("ppt/slides/slide1.xml")
        zip.write <<~XML
          <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <p:cSld><p:spTree><p:pic><p:nvPicPr><p:cNvPr name="#{marker}"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic></p:spTree></p:cSld>
          </p:sld>
        XML
        zip.put_next_entry("ppt/slides/_rels/slide1.xml.rels")
        zip.write '<Relationships><Relationship Id="image" Type="x/image" Target="../media/image.png"/></Relationships>'
        zip.put_next_entry("ppt/media/image.png")
        zip.write PptImporterTest::SAMPLE_IMAGE
      end
      ActiveStorage::Blob.stub(:build_after_unfurling, track) do
        assert_difference([ "Creative.count", "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ], 1) do
          assert_raises(IOError) { PptImporter.import(file, parent: nil, user: users(:one)) }
        end
      end
    end
    assert_equal 1, blobs.size
    assert_equal PptImporterTest::SAMPLE_IMAGE, blobs.first.download
  ensure
    Creative.skip_callback(:commit, :after, callback)
    Creative.where("description LIKE ?", "%#{marker}%").destroy_all
    blobs.each(&:purge)
  end
end
