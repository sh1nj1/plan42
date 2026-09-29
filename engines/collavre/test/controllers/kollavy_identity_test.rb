require "test_helper"

class KollavyIdentityControllerTest < ActionDispatch::IntegrationTest
  test "signup cannot claim the reserved email by supplying the system marker" do
    assert_no_difference("Collavre::User.count") do
      post collavre.users_path, params: { user: {
        email: " KOLLAVY@COLLAVRE.LOCAL ", name: "Impostor", password: "password-123",
        password_confirmation: "password-123", system_agent: true
      } }
    end
    assert_response :unprocessable_entity
  end

  test "profile updates cannot assign the system marker" do
    user = users(:two)
    sign_in_as(user, password: "password")
    patch collavre.user_path(user), params: { user: { name: "Changed", system_agent: true } }
    assert_redirected_to collavre.user_path(user)
    refute user.reload.system_agent?
  end
end
