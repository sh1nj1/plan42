require_relative "../application_system_test_case"
require "zip"

class PptViewerTest < ApplicationSystemTestCase
  driven_by :hovering_pointer_headless_chrome
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
      @creative.embed_attachment_blob!(blob)
    end
    sign_in_via_ui(@user)
  end

  test "inline viewer navigates and uses native fullscreen" do
    visit collavre.creatives_path(id: @creative.id)
    assert_selector "iframe.ppt-attachment-preview"
    within_frame(find("iframe.ppt-attachment-preview")) do
      assert_equal "0", page.evaluate_script("getComputedStyle(document.querySelector('#slide-controls')).opacity")
      find(".ppt-viewer").hover
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      assert_selector ".ppt-slide", text: "Slide 1"
      find(".ppt-viewer").hover
      assert_selector "a[download=\"slides.pptx\"]"
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
  test "editor previews uploads immediately and retains the same viewer after save" do
    visit collavre.creatives_path
    find("#creative-#{@creative.id}").hover
    find("#creative-#{@creative.id} .edit-inline-btn").click
    assert_selector "[data-lexical-editor-root][data-editor-ready='true'] iframe.ppt-attachment-preview"
    editor = find("[data-lexical-editor-root][data-editor-ready='true']")
    original_src = editor.find("iframe")["src"]
    @creative.files.first.blob.open do |file|
      Tempfile.create([ "uploaded", ".pptx" ]) do |upload|
        FileUtils.cp(file.path, upload.path)
        editor.find("input[type=file]:not([accept])", visible: false).attach_file(upload.path)
        assert_selector "[data-lexical-editor-root] iframe.ppt-attachment-preview", count: 2
      end
    end
    assert_selector "[data-lexical-editor-root] iframe.ppt-attachment-preview", count: 2
    within_frame(all("[data-lexical-editor-root] iframe.ppt-attachment-preview").last) do
      find(".ppt-viewer").hover
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      find("[data-ppt-next]").click
      assert_selector "[data-ppt-counter]", text: "2 / 2"
    end
    find("#inline-close").click
    assert_no_selector ".lexical-content-editable"
    assert_selector "#creative-#{@creative.id} iframe.ppt-attachment-preview", count: 2
    assert_equal original_src, first("#creative-#{@creative.id} iframe.ppt-attachment-preview")["src"]
  end
end
