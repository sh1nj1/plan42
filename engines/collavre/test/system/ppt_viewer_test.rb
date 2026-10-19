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
        if name.include?("standard")
          zip.put_next_entry("ppt/presentation.xml")
          zip.write %(<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldSz cx="9144000" cy="6858000"/></p:presentation>)
        end
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
    assert_selector "iframe.document-preview-frame"
    assert_preview_fills_container
    within_frame(find("iframe.document-preview-frame")) do
      assert_equal "0", page.evaluate_script("getComputedStyle(document.querySelector('#slide-controls')).opacity")
      find(".ppt-viewer").hover
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      assert_selector ".ppt-slide", text: "Slide 1"
      find(".ppt-viewer").hover
      assert_selector "a[download=\"slides.pptx\"]"
      find("[data-ppt-next]").click
      assert_selector "[data-ppt-counter]", text: "2 / 2"
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector ".ppt-viewer:fullscreen"
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector "a[download=\"slides.pptx\"]"
      assert_selector "[data-ppt-close]"
      find(".ppt-viewer-slide:not([hidden])").click
      assert_no_selector ".ppt-controls-visible"
      assert_selector "#slide-controls", style: { opacity: "0" }, visible: :all
      assert_equal "none", page.evaluate_script("getComputedStyle(document.querySelector('[data-ppt-close]')).pointerEvents")
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector ".ppt-controls-visible"
      find(".ppt-viewer").send_keys(:arrow_left)
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      find(".ppt-viewer").send_keys(:escape)
      assert_no_selector ".ppt-viewer:fullscreen"
      assert_selector ".ppt-slide", text: "Slide 1"
    end
  end
  test "fullscreen controls reveal keyboard focus without changing click toggles" do
    visit collavre.creatives_path(id: @creative.id)
    within_frame(find("iframe.document-preview-frame")) do
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector ".ppt-viewer:fullscreen"
      assert_selector "#slide-controls", style: { opacity: "0" }, visible: :all
      page.driver.browser.action.send_keys(:tab).perform
      assert_selector "#slide-controls:has(:focus-visible)", style: { opacity: "1" }
      assert_equal "auto", page.evaluate_script("getComputedStyle(document.activeElement).pointerEvents")
      assert_selector "a[download]:focus-visible"
      page.driver.browser.action.send_keys(:tab).perform
      assert_selector "[data-ppt-next]:focus-visible"
      page.driver.browser.action.send_keys(:enter).perform
      assert_selector "[data-ppt-counter]", text: "2 / 2"
      find(".ppt-viewer-slide:not([hidden])").click
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector "#slide-controls", style: { opacity: "0" }, visible: :all
    end
  end

  test "editor previews uploads immediately and retains the same viewer after save" do
    visit collavre.creatives_path
    find("#creative-#{@creative.id}").hover
    find("#creative-#{@creative.id} .edit-inline-btn").click
    assert_selector "[data-lexical-editor-root][data-editor-ready='true'] iframe.document-preview-frame"
    editor = find("[data-lexical-editor-root][data-editor-ready='true']")
    assert_preview_fills_container
    original_src = editor.find("iframe")["src"]
    @creative.files.first.blob.open do |file|
      Tempfile.create([ "uploaded", ".pptx" ]) do |upload|
        FileUtils.cp(file.path, upload.path)
        editor.find("input[type=file]:not([accept])", visible: false).attach_file(upload.path)
        assert_selector "[data-lexical-editor-root] iframe.document-preview-frame", count: 2
      end
    end
    assert_selector "[data-lexical-editor-root] iframe.document-preview-frame", count: 2
    within_frame(all("[data-lexical-editor-root] iframe.document-preview-frame").last) do
      find(".ppt-viewer").hover
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      find("[data-ppt-next]").click
      assert_selector "[data-ppt-counter]", text: "2 / 2"
    end
    find("#inline-close").click
    assert_no_selector ".lexical-content-editable"
    assert_selector "#creative-#{@creative.id} iframe.document-preview-frame", count: 2
    assert_equal original_src, first("#creative-#{@creative.id} iframe.document-preview-frame")["src"]
  end

  test "standard slides fill editor and creative width and preserve fullscreen" do
    visit collavre.creatives_path(id: @creative.id)
    assert_preview_fills_container(4.0 / 3)
    within_frame(first("iframe.document-preview-frame")) do
      find(".ppt-viewer").hover
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector ".ppt-viewer:fullscreen"
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector "a[download=\"slides.pptx\"]"
      assert_selector "[data-ppt-close]"
      find(".ppt-viewer").send_keys(:escape)
      assert_no_selector ".ppt-viewer:fullscreen"
    end
    assert_preview_fills_container(4.0 / 3)
    visit collavre.creatives_path
    find("#creative-#{@creative.id}").hover
    find("#creative-#{@creative.id} .edit-inline-btn").click
    assert_selector "[data-lexical-editor-root][data-editor-ready='true'] iframe.document-preview-frame"
    assert_preview_fills_container(4.0 / 3)
  end

  test "touch controls toggle and fullscreen provides download and close" do
    visit collavre.creatives_path(id: @creative.id)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    within_frame(find("iframe.document-preview-frame")) do
      assert page.evaluate_script("matchMedia('(hover: none)').matches")
      viewer = find(".ppt-viewer")
      assert_equal "0", page.evaluate_script("getComputedStyle(document.querySelector('#slide-controls')).opacity")
      viewer.click
      assert_selector ".ppt-controls-visible"
      find("[data-ppt-next]").click
      assert_selector "[data-ppt-counter]", text: "2 / 2"
      assert_selector ".ppt-controls-visible"
      viewer.click
      assert_no_selector ".ppt-controls-visible"
      viewer.click
      find("[data-ppt-fullscreen]").click
      assert_selector ".ppt-viewer:fullscreen"
      viewer.click
      assert_selector "a[download]"
      find("[data-ppt-close]").click
      assert_no_selector ".ppt-viewer:fullscreen"
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "touch controls provide download without fullscreen support" do
    script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument",
      source: "Element.prototype.requestFullscreen = undefined")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    visit collavre.creatives_path(id: @creative.id)
    within_frame(find("iframe.document-preview-frame")) do
      assert page.evaluate_script("typeof document.querySelector('.ppt-viewer').requestFullscreen === 'undefined'")
      find(".ppt-viewer").click
      assert_selector "a[download]"
      assert_no_selector "[data-ppt-fullscreen]"
      assert_no_selector "[data-ppt-close]"
    end
  ensure
    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: script.fetch("identifier")) if script
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "download remains available when fullscreen request is rejected" do
    visit collavre.creatives_path(id: @creative.id)
    within_frame(find("iframe.document-preview-frame")) do
      page.execute_script("document.querySelector('.ppt-viewer').requestFullscreen = () => Promise.reject(new Error('Denied'))")
      find(".ppt-viewer-slide:not([hidden])").click
      assert_selector "[data-ppt-error]"
      assert_selector "a[download]"
      assert_no_selector "[data-ppt-close]"
    end
  end

  test "preview follows available row width as the viewport grows and shrinks" do
    visit collavre.creatives_path
    [ 900, 1400, 800 ].each do |width|
      page.current_window.resize_to(width, 1000)
      assert_preview_fills_container
      frame = first("iframe.document-preview-frame")
      sizes = page.evaluate_script(<<~JS, frame)
        ((frame) => {
          const row = frame.closest('.creative-row-start');
          return [frame.getBoundingClientRect().right, row.getBoundingClientRect().right];
        })(arguments[0])
      JS
      assert_in_delta sizes[1], sizes[0], 4
    end
    find("#creative-#{@creative.id}").hover
    find("#creative-#{@creative.id} .edit-inline-btn").click
    assert_selector "[data-lexical-editor-root][data-editor-ready='true'] iframe.document-preview-frame"
    [ 1400, 800 ].each do |width|
      page.current_window.resize_to(width, 1000)
      assert_preview_fills_container
    end
  end

  test "navigation buttons stay centered while pressed" do
    visit collavre.creatives_path(id: @creative.id)
    within_frame(first("iframe.document-preview-frame")) do
      find(".ppt-viewer").hover
      [ "next", "previous" ].each do |direction|
        button = find("[data-ppt-#{direction}]")
        before = button.rect.y
        page.driver.browser.action.move_to(button.native).click_and_hold.perform
        sleep 0.2
        assert_in_delta before, button.rect.y, 0.5
        page.driver.browser.action.release.perform
      end
    end
  end

  test "markdown and html use a sandboxed document with shared fullscreen and loading" do
    { "notes.md" => "# Document heading", "page.html" => '<h1>Document heading</h1><script>parent.compromised=true</script>' }.each do |filename, source|
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(source), filename: filename)
      @creative.embed_attachment_blob!(blob)
    end
    visit collavre.creatives_path(id: @creative.id)
    assert_selector ".ppt-attachment-preview[aria-busy='false']", count: 3
    all("iframe.document-preview-frame").drop(1).each do |frame|
      within_frame(frame) do
        assert_selector ".document-viewer"
        within_frame(find("iframe[sandbox]")) { assert_selector "h1", text: "Document heading" }
        assert_nil page.evaluate_script("window.compromised")
        find("[data-ppt-fullscreen]").click
        assert_selector ".document-viewer:fullscreen"
        find("[data-ppt-close]").click
        assert_no_selector ".document-viewer:fullscreen"
      end
    end
  end

  test "pdf uses shared overlay controls for navigation zoom and fullscreen" do
    blob = ActiveStorage::Blob.create_and_upload!(io: File.open(File.expand_path("../fixtures/files/document_viewer.pdf", __dir__)), filename: "paper.pdf", content_type: "application/pdf")
    @creative.embed_attachment_blob!(blob)
    visit collavre.creatives_path(id: @creative.id)
    within_frame(all("iframe.document-preview-frame").last) do
      assert_selector ".pdf-document canvas"
      assert_selector "#slide-controls", style: { opacity: "0" }, visible: :all
      find(".pdf-viewer").hover
      assert_selector "#slide-controls", style: { position: "absolute", opacity: "1" }
      assert_selector "[data-ppt-previous]", style: { left: "0px" }
      assert_selector "[data-ppt-next]", style: { right: "0px" }
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      assert_no_selector ".media-loading"
      find("[data-ppt-next]").click
      assert_selector "[data-ppt-counter]", text: "2 / 2"
      find(".pdf-viewer").send_keys(:arrow_left)
      assert_selector "[data-ppt-counter]", text: "1 / 2"
      find("[data-pdf-zoom]").click
      assert_no_selector "[data-document-error]"
      find(".pdf-document canvas").click
      assert_selector ".pdf-viewer:fullscreen"
      find(".pdf-document canvas").click
      assert_selector ".ppt-controls-visible"
      find("[data-ppt-close]").click
      assert_no_selector ".pdf-viewer:fullscreen"
    end
  end

  private

  def assert_preview_fills_container(ratio = 16.0 / 9)
    assert_selector 'iframe.document-preview-frame[style*="aspect-ratio"]'
    dimensions = page.evaluate_script(<<~JS, first("iframe.document-preview-frame"))
      ((frame) => {
        const container = frame.closest('.lexical-content-editable') || frame.parentElement;
        const style = getComputedStyle(container);
        return {
          width: frame.getBoundingClientRect().width,
          available: container.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
          height: frame.getBoundingClientRect().height
        };
      })(arguments[0])
    JS
    assert_in_delta dimensions["available"], dimensions["width"], 2
    assert_in_delta dimensions["width"] / ratio, dimensions["height"], 2
    within_frame(first("iframe.document-preview-frame")) do
      assert_selector ".ppt-slide"
      slide_width = page.evaluate_script("document.querySelector('.ppt-slide').getBoundingClientRect().width")
      assert_in_delta dimensions["width"], slide_width, 2
    end
  end
end
