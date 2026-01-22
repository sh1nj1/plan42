require "test_helper"

class Webauthn::CredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two)
    @credential = WebauthnCredential.create!(
      user: @user,
      webauthn_id: "test_credential_id",
      public_key: "public_key",
      sign_count: 0
    )
  end

  test "should destroy credential" do
    sign_in_as(@user, password: "password")

    assert_difference("WebauthnCredential.count", -1) do
      delete webauthn_credential_url(@credential)
    end

    assert_redirected_to root_path
    assert_equal I18n.t("users.webauthn.deleted"), flash[:notice]
  end

  test "should not destroy credential of another user" do
    @other_user = users(:one)
    sign_in_as(@other_user, password: "password")

    assert_no_difference("WebauthnCredential.count") do
      delete webauthn_credential_url(@credential)
    end

    # Ideally should be 404 or prohibited, but Rails default for find is 404
    assert_response :not_found
  end
end
