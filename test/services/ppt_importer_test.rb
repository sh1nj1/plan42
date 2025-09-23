require "test_helper"
require "zip"
require "base64"

class PptImporterTest < ActiveSupport::TestCase
  SAMPLE_IMAGE = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=")

  test "creates creatives with html for each slide" do
    user = User.create!(email: "ppt@example.com", password: "password", name: "Presenter")
    parent = Creative.create!(user: user, description: "Root")

    Tempfile.create([ "sample", ".pptx" ]) do |tmp|
      build_sample_pptx(tmp)
      tmp.rewind

      created = PptImporter.import(tmp, parent: parent, user: user, create_root: false)

      assert_equal 2, created.length
      slide1_html = created.first.description.body.to_html
      slide2_html = created.second.description.body.to_html

      assert_includes slide1_html, "<p>Slide 1</p>"
      assert_includes slide1_html, "img src=\"data:image/png;base64"
      assert_includes slide2_html, "<p>Slide 2</p>"
    end
  end

  private

  def build_sample_pptx(tmp)
    Zip::OutputStream.open(tmp.path) do |zip|
      slide1_xml = <<~XML
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:txBody>
                  <a:p><a:r><a:t>Slide 1</a:t></a:r></a:p>
                </p:txBody>
              </p:sp>
              <p:pic>
                <p:blipFill>
                  <a:blip r:embed="rId1"/>
                </p:blipFill>
              </p:pic>
            </p:spTree>
          </p:cSld>
        </p:sld>
      XML
      zip.put_next_entry("ppt/slides/slide1.xml")
      zip.write(slide1_xml)

      rels1_xml = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
        </Relationships>
      XML
      zip.put_next_entry("ppt/slides/_rels/slide1.xml.rels")
      zip.write(rels1_xml)

      zip.put_next_entry("ppt/media/image1.png")
      zip.write(SAMPLE_IMAGE)

      slide2_xml = <<~XML
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:txBody>
                  <a:p><a:r><a:t>Slide 2</a:t></a:r></a:p>
                </p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
      XML
      zip.put_next_entry("ppt/slides/slide2.xml")
      zip.write(slide2_xml)
    end
  end
end
