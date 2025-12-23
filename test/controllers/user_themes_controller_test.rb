require "test_helper"

class UserThemesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")
  end

  test "should get index" do
    get user_themes_url
    assert_response :success
  end
end
