require "test_helper"
require "zip"

class PptPreviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @creative = Creative.create!(user: users(:one), description: "Presentation")
    @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("pptx"), filename: "deck.pptx")
    @creative.files.attach(@blob)
    @attachment = @creative.files.last
    @path = collavre.creative_ppt_preview_path(@creative, @attachment)
    sign_in_as(users(:one), password: "password")
  end

  test "display pages expose request-aware preview routes under an engine prefix" do
    Rails.application.routes.draw do
      mount Collavre::Engine => "/collavre", as: "collavre"
      get "/rails/active_storage/blobs/redirect/:signed_id/*filename", to: "active_storage/blobs/redirect#show", as: :rails_service_blob
      post "/rails/active_storage/direct_uploads", to: "active_storage/direct_uploads#create", as: :rails_direct_uploads
      get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
    end
    [ "/collavre/creatives?id=#{@creative.id}", "/collavre/creatives/#{@creative.id}/slide_view" ].each do |path|
      get path
      assert_response :success
      assert_select 'meta[name="ppt-preview-url-template"][content="/collavre/ppt_previews/PPT_BLOB_ID"]'
    end
  ensure
    Rails.application.reload_routes!
  end

  test "owner can view cached slides without creating creatives" do
    Collavre::PptPreview.stub :slides, [ '<div class="ppt-slide">First</div>', '<div class="ppt-slide">Second</div>' ] do
      assert_no_difference "Creative.count" do
        get @path
      end
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_select ".ppt-viewer-slide", count: 2
      assert_select ".ppt-viewer-slide[hidden]", count: 1
      assert_select "link[href*='collavre/slide_view']"
    end
  end

  test "denied access never reads cached slides" do
    sign_in_as(users(:two), password: "password")
    Collavre::PptPreview.stub :slides, ->(*) { flunk "Must authorize before rendering" } do
      get @path
      assert_response :forbidden
    end
  end

  test "anonymous private access denied and public access permitted" do
    sign_out
    get @path
    assert_response :forbidden
    CreativeShare.create!(creative: @creative, user: nil, permission: :read)
    Collavre::PptPreview.stub :slides, [ "Public" ] do
      get @path
      assert_response :success
    end
  end

  test "global login policy blocks anonymous public previews before rendering" do
    CreativeShare.create!(creative: @creative, user: nil, permission: :read)
    SystemSetting.create!(key: "creatives_login_required", value: "true")
    sign_out

    Collavre::PptPreview.stub :slides, ->(*) { flunk "Must require login before rendering" } do
      get @path
      assert_redirected_to collavre.new_session_path
    end
  end

  test "global login policy allows authenticated previews" do
    SystemSetting.create!(key: "creatives_login_required", value: "true")
    Collavre::PptPreview.stub :slides, [ "Private" ] do
      get @path
      assert_response :success
    end
  end

  test "linked shell legacy attachments cannot be read through public origin permissions" do
    CreativeShare.create!(creative: @creative, user: nil, permission: :read)
    linked = Creative.create!(user: users(:two), origin: @creative)
    linked.files.attach(io: StringIO.new("private deck"), filename: "private.pptx")
    legacy_attachment = linked.files.last
    sign_out

    Collavre::PptPreview.stub :slides, ->(*) { flunk "Must not render a shell-owned attachment" } do
      get collavre.creative_ppt_preview_path(linked, legacy_attachment)
      assert_response :not_found
    end
  end

  test "linked preview resolves origin before attachment lookup and authorization" do
    linked = Creative.create!(user: users(:two), origin: @creative)
    sign_out
    Collavre::PptPreview.stub :slides, ->(*) { flunk "Must authorize the origin before rendering" } do
      get collavre.creative_ppt_preview_path(linked, @attachment)
      assert_response :forbidden
    end

    CreativeShare.create!(creative: @creative, user: nil, permission: :read)
    Collavre::PptPreview.stub :slides, ->(blob) { assert_equal @blob, blob; [ "Origin presentation" ] } do
      get collavre.creative_ppt_preview_path(linked, @attachment)
      assert_response :success
    end
  end

  test "attachments from another creative and missing attachments are rejected" do
    other = Creative.create!(user: users(:one), description: "Other")
    get collavre.creative_ppt_preview_path(other, @attachment)
    assert_response :not_found
    get collavre.creative_ppt_preview_path(@creative, 0)
    assert_response :not_found
  end

  test "markdown renders headings tables and code in a sandboxed document" do
    @creative.files.attach(ActiveStorage::Blob.create_and_upload!(io: StringIO.new("# Notes\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n```ruby\nputs 1\n```"), filename: "notes.md"))
    get collavre.ppt_preview_path(@creative.files.last.blob.signed_id)
    assert_response :success
    assert_select ".document-viewer"
    assert_select "iframe[sandbox='']" do |frames|
      html = Nokogiri::HTML.parse(frames.first["srcdoc"])
      assert_equal "Notes", html.at_css("h1").text
      assert html.at_css("table")
      assert html.at_css("pre code")
    end
    assert_select ".ppt-viewer h1, .ppt-viewer style", count: 0
    assert_select "[data-ppt-fullscreen]"
    assert_select "[data-ppt-next]", count: 0
  end

  test "html source stays escaped inside a sandbox without script permissions" do
    source = '<h1>Report</h1><script>window.parent.compromised=true</script>'
    @creative.files.attach(ActiveStorage::Blob.create_and_upload!(io: StringIO.new(source), filename: "report.HTML"))
    get collavre.ppt_preview_path(@creative.files.last.blob.signed_id)
    assert_response :success
    assert_select "iframe[sandbox='']" do |frames|
      assert_equal source, frames.first["srcdoc"]
    end
    assert_select ".ppt-viewer > script", count: 0
  end

  test "pdf uses a local PDF.js worker and shared document controls" do
    @blob.update!(filename: "report.pdf")
    get @path
    assert_response :success
    assert_select ".ppt-viewer.document-viewer.pdf-viewer"
    assert_select ".pdf-document[data-pdf-src][data-pdf-worker]" do |elements|
      assert_match %r{/collavre_pdf_worker[^/]*\.js}, elements.first["data-pdf-worker"]
    end
    assert_select "script[src]" do |scripts|
      assert scripts.any? { |script| script["src"].match?(%r{/collavre_pdf_viewer[^/]*\.js}) }
    end
    assert_select "[data-pdf-zoom]"
    assert_select "[data-ppt-next]"
    assert_select ".media-loading[role=status]"
  end

  test "preview accessibility labels describe documents pages and slides in both locales" do
    { en: [ "Document controls", "Page navigation", "Previous page", "Next page", "Slide navigation" ],
      ko: [ "문서 제어", "페이지 탐색", "이전 페이지", "다음 페이지", "슬라이드 탐색" ] }.each do |locale, labels|
      users(:one).update!(locale: locale)
      %w[md html pdf pptx].each do |extension|
        @blob.update!(filename: "document.#{extension}")
        Collavre::PptPreview.stub :slides, [ "Slide" ] do
          get @path, params: { locale: locale }
        end
        assert_response :success
        navigation = extension == "pptx" ? labels[4] : (extension == "pdf" ? labels[1] : labels[0])
        assert_select ".ppt-viewer[aria-label=?]", navigation
        assert_select "nav[aria-label=?]", navigation
        if extension == "pdf"
          assert_select "[data-ppt-previous][aria-label=?]", labels[2]
          assert_select "[data-ppt-next][aria-label=?]", labels[3]
        end
      end
    end
  end

  test "document size limit is applied before downloading" do
    @blob.update!(filename: "large.md", byte_size: 10.megabytes + 1)
    get @path
    assert_response :unprocessable_entity
  end

  test "new formats retain creative authorization" do
    sign_in_as(users(:two), password: "password")
    %w[md html pdf].each do |extension|
      @blob.update!(filename: "private.#{extension}")
      get @path
      assert_response :forbidden
      get collavre.ppt_preview_path(@blob.signed_id)
      assert_response :not_found
    end
  end

  test "non pptx attachments are rejected" do
    @blob.update!(filename: "notes.txt")
    get @path
    assert_response :not_found
  end

  test "invalid presentations return translated error" do
    [ Collavre::PptRenderer::InvalidArchive, Zip::Error, Nokogiri::XML::SyntaxError ].each do |error|
      Collavre::PptPreview.stub :slides, ->(*) { raise error, "invalid" } do
        get @path
        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre.ppt_viewer.invalid"), response.body
      end
    end
  end
  test "signed blob route authorizes attached creative before rendering" do
    path = collavre.ppt_preview_path(@blob.signed_id)
    Collavre::PptPreview.stub :slides, [ "Slide" ] do
      get path
      assert_response :success
      assert_select "a[download='deck.pptx']"
      sign_in_as(users(:two), password: "password")
      get path
      assert_response :not_found
      sign_out
      get path
      assert_response :not_found
      CreativeShare.create!(creative: @creative, user: nil, permission: :read)
      get path
      assert_response :success
      SystemSetting.create!(key: "creatives_login_required", value: "true")
      get path
      assert_redirected_to collavre.new_session_path
    end
  end

  test "only uploader can preview an unsaved direct upload" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("pptx"), filename: "new.pptx",
      metadata: { Collavre::BlobAccess::UPLOADER_METADATA_KEY => users(:one).id.to_s })
    path = collavre.ppt_preview_path(blob.signed_id)
    Collavre::PptPreview.stub :slides, [ "Slide" ] do
      get path
      assert_response :success
      sign_in_as(users(:two), password: "password")
      get path
      assert_response :not_found
      sign_out
      get path
      assert_response :not_found
    end
  end

  test "signed blob route rejects invalid IDs non pptx and private shell files" do
    get collavre.ppt_preview_path("invalid")
    assert_response :not_found
    @blob.update!(filename: "notes.txt")
    get collavre.ppt_preview_path(@blob.signed_id)
    assert_response :not_found
    CreativeShare.create!(creative: @creative, user: nil, permission: :read)
    linked = Creative.create!(user: users(:two), origin: @creative)
    linked.files.attach(io: StringIO.new("private"), filename: "legacy.pptx")
    sign_out
    get collavre.ppt_preview_path(linked.files.last.blob.signed_id)
    assert_response :not_found
  end
end
