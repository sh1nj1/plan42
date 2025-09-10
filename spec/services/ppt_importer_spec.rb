require 'rails_helper'
require 'zip'
require 'base64'

describe PptImporter do
  it 'creates creatives with HTML for each slide' do
    user = User.create!(email: 'test@example.com', password: 'password', name: 'Test')
    parent = Creative.create!(user: user, description: 'Root')

    Tempfile.create([ 'sample', '.pptx' ]) do |tmp|
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
        zip.put_next_entry('ppt/slides/slide1.xml')
        zip.write(slide1_xml)

        rels1_xml = <<~XML
          <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
          </Relationships>
        XML
        zip.put_next_entry('ppt/slides/_rels/slide1.xml.rels')
        zip.write(rels1_xml)

        zip.put_next_entry('ppt/media/image1.png')
        zip.write(Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII='))

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
        zip.put_next_entry('ppt/slides/slide2.xml')
        zip.write(slide2_xml)
      end

      tmp.rewind
      created = PptImporter.import(tmp, parent: parent, user: user, create_root: false)
      expect(created.length).to eq(2)
      slide1_html = created.first.description.body.to_html
      slide2_html = created.second.description.body.to_html
      expect(slide1_html).to include('<p>Slide 1</p>')
      expect(slide1_html).to include('img src="data:image/png;base64')
      expect(slide2_html).to include('<p>Slide 2</p>')
    end
  end
end
