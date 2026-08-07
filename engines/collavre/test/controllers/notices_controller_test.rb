require "test_helper"

class NoticesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "dismiss adds the key to dismissed_notices" do
    post "/notices/slash_command/dismiss"
    assert_response :success
    assert_equal [ "slash_command" ], @user.reload.dismissed_notices
  end

  test "dismiss is idempotent" do
    @user.update!(dismissed_notices: [ "slash_command" ])
    post "/notices/slash_command/dismiss"
    assert_response :success
    assert_equal [ "slash_command" ], @user.reload.dismissed_notices
  end

  test "restore_all clears dismissed_notices" do
    @user.update!(dismissed_notices: [ "slash_command", "add_user" ])
    delete "/notices"
    assert_response :success
    assert_equal [], @user.reload.dismissed_notices
  end
end
