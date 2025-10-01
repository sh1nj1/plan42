require "test_helper"

class Users::SharedCreativesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @recipient = users(:two)
    @creative = creatives(:tshirt)
    CreativeShare.create!(creative: @creative, user: @recipient, permission: :read)
  end

  test "owner can view shared creative details" do
    sign_in_as(@owner, password: "password")

    get user_shared_creative_path(@owner, @creative)
    assert_response :success
    assert_includes response.body, @recipient.display_name
    assert_includes response.body, I18n.t("users.shared_creatives.permissions.read")
  end

  test "other users cannot view shared creative details" do
    sign_in_as(@recipient, password: "password")

    get user_shared_creative_path(@owner, @creative)
    assert_response :not_found
  end
end
