require "test_helper"

class CreativeImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "import@example.com", password: TEST_PASSWORD, name: "Importer", email_verified_at: Time.current)
    sign_in_as(@user)
  end

  test "imports markdown files" do
    file = fixture_file_upload("sample.md", "text/markdown")

    before_count = Creative.count
    post collavre.creative_imports_path, params: { markdown: file }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert json["created"].present?
    assert_operator Creative.count, :>, before_count
  end

  test "rejects unsupported file types" do
    file = fixture_file_upload("invalid.txt", "text/plain")

    assert_no_difference("Creative.count") do
      post collavre.creative_imports_path, params: { markdown: file }
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Invalid file type", json["error"]
  end

  test "rejects pptx uploads with an invalid MIME label" do
    file = Rack::Test::UploadedFile.new(
      file_fixture("invalid.txt"), "text/plain", original_filename: "slides.pptx"
    )

    assert_no_difference("Creative.count") do
      post collavre.creative_imports_path, params: { markdown: file }
    end

    assert_response :unprocessable_entity
    assert_equal "Invalid file type", JSON.parse(response.body)["error"]
  end

  test "rejects legacy binary PowerPoint files" do
    file = Rack::Test::UploadedFile.new(
      file_fixture("invalid.txt"),
      "application/vnd.ms-powerpoint",
      original_filename: "legacy.ppt"
    )

    assert_no_difference("Creative.count") do
      post collavre.creative_imports_path, params: { markdown: file }
    end

    assert_response :unprocessable_entity
    assert_equal "Invalid file type", JSON.parse(response.body)["error"]
  end

  test "accepts pptx uploads with the generic PowerPoint MIME label" do
    Tempfile.create([ "presentation", ".pptx" ]) do |tmp|
      Zip::OutputStream.open(tmp.path) do |zip|
        zip.put_next_entry("ppt/slides/slide1.xml")
        zip.write('<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree/></p:cSld></p:sld>')
      end
      file = Rack::Test::UploadedFile.new(tmp.path, "application/vnd.ms-powerpoint", original_filename: "slides.pptx")
      assert_difference("Creative.count", 2) do
        post collavre.creative_imports_path, params: { markdown: file }
      end
      assert_response :success
      assert JSON.parse(response.body)["success"]
    end
  end

  test "rejects nonnumeric fallback slide names without creating records" do
    %w[slide.xml slideNotes.xml slide1extra.xml].each do |name|
      Tempfile.create([ "presentation", ".pptx" ]) do |tmp|
        Zip::OutputStream.open(tmp.path) do |zip|
          [ "slide1.xml", name ].each do |slide_name|
            zip.put_next_entry("ppt/slides/#{slide_name}")
            zip.write('<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree/></p:cSld></p:sld>')
          end
        end
        file = Rack::Test::UploadedFile.new(tmp.path, "application/vnd.ms-powerpoint", original_filename: "slides.pptx")
        assert_no_difference([ "Creative.count", "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ]) do
          post collavre.creative_imports_path, params: { markdown: file }
        end
        assert_response :unprocessable_entity
        assert_equal "Invalid file type", JSON.parse(response.body)["error"]
      end
    end
  end

  test "rejects excessive rendered output as a validation error without records" do
    limit = Collavre::PptImporter::MAX_RENDERED_BYTES
    Collavre::PptImporter.send(:remove_const, :MAX_RENDERED_BYTES)
    Collavre::PptImporter.const_set(:MAX_RENDERED_BYTES, 1)
    Tempfile.create([ "presentation", ".pptx" ]) do |tmp|
      Zip::OutputStream.open(tmp.path) do |zip|
        zip.put_next_entry("ppt/slides/slide1.xml")
        zip.write('<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree/></p:cSld></p:sld>')
      end
      file = Rack::Test::UploadedFile.new(tmp.path, "application/vnd.ms-powerpoint", original_filename: "slides.pptx")
      assert_no_difference([ "Creative.count", "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ]) do
        post collavre.creative_imports_path, params: { markdown: file }
      end
      assert_response :unprocessable_entity
      assert_equal "Invalid file type", JSON.parse(response.body)["error"]
    end
  ensure
    Collavre::PptImporter.send(:remove_const, :MAX_RENDERED_BYTES)
    Collavre::PptImporter.const_set(:MAX_RENDERED_BYTES, limit)
  end

  test "rejects corrupt pptx bytes as a validation error" do
    file = Rack::Test::UploadedFile.new(
      file_fixture("invalid.txt"),
      "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      original_filename: "broken.pptx"
    )
    assert_no_difference("Creative.count") do
      post collavre.creative_imports_path, params: { markdown: file }
    end
    assert_response :unprocessable_entity
    assert_equal "Invalid file type", JSON.parse(response.body)["error"]
  end

  test "returns unauthorized when user not signed in" do
    delete session_path

    post collavre.creative_imports_path, params: { markdown: fixture_file_upload("sample.md", "text/markdown") }

    assert_response :unauthorized
  end
end
