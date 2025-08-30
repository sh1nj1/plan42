require "test_helper"

class LocaleUpdateTest < ActionDispatch::IntegrationTest
  test "user can update locale" do
    user = users(:one)
    user.update!(email_verified_at: Time.current)
    post session_path, params: { email: user.email, password: "password" }
    assert_response :redirect

    patch user_path(user), params: { user: { locale: "ko" } }
    assert_redirected_to user_path(user)

    assert_equal "ko", user.reload.locale
  end

  test "preselects saved locale on profile form" do
    user = users(:one)
    user.update!(email_verified_at: Time.current, locale: "ko")
    post session_path, params: { email: user.email, password: "password" }
    assert_response :redirect

    get user_path(user)
    assert_match /option selected=\"selected\" value=\"ko\"/, response.body
  end
end
