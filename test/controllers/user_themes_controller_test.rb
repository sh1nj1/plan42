require "test_helper"

class UserThemesControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get user_themes_index_url
    assert_response :success
  end
end
