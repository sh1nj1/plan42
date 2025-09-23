require "test_helper"

class SessionTimezoneTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "user@example.com", password: "pw", name: "User", email_verified_at: Time.current)
  end

  test "stores timezone on login" do
    post session_path, params: { email: @user.email, password: "pw", timezone: "Asia/Tokyo" }
    assert_redirected_to root_url
    assert_equal "Asia/Tokyo", @user.reload.timezone
  end

  test "allows clearing timezone from profile" do
    post session_path, params: { email: @user.email, password: "pw" }
    patch user_path(@user), params: { user: { name: "User", timezone: "" } }
    assert_redirected_to user_url(@user)
    assert_nil @user.reload.timezone
  end

  test "accepts city names for timezone" do
    post session_path, params: { email: @user.email, password: "pw" }
    patch user_path(@user), params: { user: { name: "User", timezone: "Seoul" } }
    assert_redirected_to user_url(@user)
    assert_equal "Asia/Seoul", @user.reload.timezone
  end

  test "preselects saved timezone on profile form" do
    @user.update!(timezone: "Asia/Seoul")
    post session_path, params: { email: @user.email, password: "pw" }
    get user_path(@user)
    assert_includes response.body, "option selected=\"selected\" value=\"Asia/Seoul\""
  end
end
