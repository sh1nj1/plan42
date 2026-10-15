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
