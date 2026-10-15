require_relative "../application_system_test_case"
require "zip"

class PptViewerTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "ppt-viewer@example.com", password: SystemHelpers::PASSWORD,
                        name: "PPT Viewer", email_verified_at: Time.current, notifications_enabled: false)
    @creative = Creative.create!(user: @user, description: "Presentation")
    Tempfile.create([ "viewer", ".pptx" ]) do |file|
      Zip::OutputStream.open(file.path) do |zip|
        2.times do |index|
          zip.put_next_entry("ppt/slides/slide#{index + 1}.xml")
          zip.write %(<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Slide #{index + 1}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>)
        end
      end
      blob = ActiveStorage::Blob.create_and_upload!(io: File.open(file.path), filename: "slides.pptx")
      @creative.files.attach(blob)
    end
    sign_in_via_ui(@user)
  end

  test "inline viewer navigates and uses native fullscreen" do
    visit collavre.creatives_path(id: @creative.id)
    assert_selector "iframe.ppt-attachment-preview"
    within_frame(find("iframe.ppt-attachment-preview")) do
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      assert_selector ".ppt-slide", text: "Slide 1"
      find("[data-ppt-next]").click
      assert_selector "[data-ppt-counter]", text: "2 / 2"
      find("[data-ppt-fullscreen]").click
      assert_selector ".ppt-viewer:fullscreen"
      find(".ppt-viewer").send_keys(:arrow_left)
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      find(".ppt-viewer").send_keys(:escape)
      assert_no_selector ".ppt-viewer:fullscreen"
      assert_selector ".ppt-slide", text: "Slide 1"
    end
  end
end
