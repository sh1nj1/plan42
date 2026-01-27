require "test_helper"

class CompletionMarkUpdateTest < ActionDispatch::IntegrationTest
  test "user can update completion mark" do
    user = users(:one)
    user.update!(email_verified_at: Time.current)
    post session_path, params: { email: user.email, password: "password" }
    assert_response :redirect

    patch user_path(user), params: { user: { completion_mark: "✓" } }
    assert_redirected_to user_path(user)

    user.reload
    assert_equal "✓", user.completion_mark
  end
end
