require 'rails_helper'
require 'zip'

describe PptImporter do
  it 'creates creatives for each slide' do
    user = User.create!(email: 'test@example.com', password: 'password', name: 'Test')
    parent = Creative.create!(user: user, description: 'Root')
    Tempfile.create([ 'sample', '.pptx' ]) do |tmp|
      Zip::OutputStream.open(tmp.path) do |zip|
        slide_xml = '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>%{text}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
        zip.put_next_entry('ppt/slides/slide1.xml')
        zip.write(slide_xml % { text: 'Slide 1' })
        zip.put_next_entry('ppt/slides/slide2.xml')
        zip.write(slide_xml % { text: 'Slide 2' })
      end
      tmp.rewind
      created = PptImporter.import(tmp, parent: parent, user: user, create_root: false)
      expect(created.length).to eq(2)
      expect(created.map { |c| c.description.to_plain_text }).to include('Slide 1', 'Slide 2')
    end
  end
end
