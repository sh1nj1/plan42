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

  test "reset_onboarding removes the guide and starts a fresh guide on the redirected index" do
    @user.update!(onboarding_seeded_at: nil)
    guide = Collavre::Onboarding::Seeder.call(user: @user)

    delete collavre.reset_onboarding_path

    assert_redirected_to collavre.creatives_path
    assert_not Collavre::Creative.exists?(guide.id)
    assert_nil @user.reload.onboarding_seeded_at

    follow_redirect!
    replacement = Collavre::Creative.onboarding_guides.find_by!(user: @user)
    assert_redirected_to collavre.creatives_path(id: replacement.id)
  end

  test "reset_onboarding preserves the engine mount prefix" do
    delete collavre.reset_onboarding_path, env: { "SCRIPT_NAME" => "/collavre" }

    assert_redirected_to collavre.creatives_path(script_name: "/collavre")
  end
end
