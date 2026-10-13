require "test_helper"

class CreativesControllerLegacyPublicRedirectTest < ActionDispatch::IntegrationTest
  setup do
    SystemSetting.where(key: "creatives_login_required").destroy_all
    @creative = Collavre::Creative.create!(user: users(:one), description: "<p>Public Plan</p>")
    perform_enqueued_jobs { Collavre::CreativeShare.create!(creative: @creative, user: nil, permission: :read) }
  end

  test "signed-out legacy links to public content move to the public page" do
    get creatives_path(id: @creative.id)

    public_id = @creative.reload.public_id
    assert_not_nil public_id
    assert_response :moved_permanently
    assert_redirected_to public_creative_path(public_id: public_id, slug: "public-plan")
  end

  test "a linked creative redirects to its origin's public page" do
    link = Collavre::Creative.create!(user: users(:two), origin: @creative)

    get creatives_path(id: link.id)

    assert_redirected_to public_creative_path(public_id: @creative.reload.public_id, slug: "public-plan")
    assert_nil link.reload.public_id
  end

  test "signed-in readers keep the app view" do
    sign_in_as(users(:one), password: "password")

    get creatives_path(id: @creative.id)

    assert_response :success
  end

  test "links with more than the id keep the app view" do
    get creatives_path(id: @creative.id, open_comments: true)

    assert_response :success
  end

  test "turbo frame navigations keep the app view" do
    get creatives_path(id: @creative.id), headers: { "Turbo-Frame" => "main" }

    assert_response :success
  end

  test "private content is not redirected" do
    private_creative = Collavre::Creative.create!(user: users(:one), description: "Private")

    get creatives_path(id: private_creative.id)

    assert_response :success
    assert_nil private_creative.reload.public_id
  end
end
