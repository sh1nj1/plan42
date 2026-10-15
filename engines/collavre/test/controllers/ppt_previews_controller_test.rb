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

  test "creative screen embeds pptx with fullscreen permission" do
    get collavre.creatives_path(id: @creative.id)
    assert_response :success
    assert_select "iframe.ppt-attachment-preview[allowfullscreen][loading=lazy]" do |frames|
      assert_equal @path, frames.first["src"]
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
end
