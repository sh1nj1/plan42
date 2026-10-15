require "test_helper"
require "zip"

class PptPreviewTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "renders and caches by blob and locale without creating records" do
    blob = presentation_blob("First")
    assert_no_difference [ "Creative.count", "ActiveStorage::Blob.count" ] do
      first = Collavre::PptPreview.slides(blob)
      assert_includes first.first, "First"
      Collavre::PptRenderer.stub :new, ->(*) { flunk "Expected cached output" } do
        assert_equal first, Collavre::PptPreview.slides(blob)
      end
    end
  end

  test "distinct blobs have distinct cache entries" do
    assert_includes Collavre::PptPreview.slides(presentation_blob("First")).first, "First"
    assert_includes Collavre::PptPreview.slides(presentation_blob("Second")).first, "Second"
  end

  test "cache includes locale and does not cache failures" do
    blob = presentation_blob("Localized")
    I18n.with_locale(:en) { Collavre::PptPreview.slides(blob) }
    calls = 0
    renderer = Object.new
    renderer.define_singleton_method(:render) { calls += 1; raise Collavre::PptRenderer::InvalidArchive }
    Collavre::PptRenderer.stub :new, renderer do
      I18n.with_locale(:ko) do
        2.times { assert_raises(Collavre::PptRenderer::InvalidArchive) { Collavre::PptPreview.slides(blob) } }
      end
    end
    assert_equal 2, calls
  end

  test "rejects oversized blobs before download" do
    blob = presentation_blob("Large")
    blob.update!(byte_size: Collavre::PptRenderer::MAX_TOTAL_BYTES + 1)
    assert_raises(Collavre::PptRenderer::InvalidArchive) { Collavre::PptPreview.slides(blob) }
  end

  test "inline pictures are embedded safely without uploading extracted blobs" do
    Tempfile.create([ "pictures", ".pptx" ]) do |file|
      Zip::OutputStream.open(file.path) do |zip|
        zip.put_next_entry("ppt/media/image.png")
        zip.write "png"
        zip.put_next_entry("ppt/media/image.html")
        zip.write '<html><script>alert(1)</script></html>'
      end
      renderer = Collavre::PptRenderer.new(file, inline_media: true)
      Zip::File.open(file) do |zip|
        renderer.instance_variable_set(:@zip, zip)
        renderer.send(:validate_archive!)
        assert_equal "data:image/png;base64,cG5n", renderer.send(:picture_source, zip.find_entry("ppt/media/image.png"))
        assert_equal "", renderer.send(:picture_source, zip.find_entry("ppt/media/image.html"))
      end
    end
  end

  test "rejects empty archives" do
    Tempfile.create([ "empty", ".pptx" ]) do |file|
      Zip::OutputStream.open(file.path) { |zip| zip.put_next_entry("other.xml"); zip.write "<x/>" }
      assert_raises(Collavre::PptRenderer::InvalidArchive) { Collavre::PptRenderer.new(file).render }
    end
  end

  private

  def presentation_blob(text)
    Tempfile.create([ "preview", ".pptx" ]) do |file|
      Zip::OutputStream.open(file.path) do |zip|
        zip.put_next_entry("ppt/slides/slide1.xml")
        zip.write %(<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>#{text}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>)
      end
      ActiveStorage::Blob.create_and_upload!(io: File.open(file.path), filename: "deck.pptx")
    end
  end
end
