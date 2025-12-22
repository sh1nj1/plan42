require "test_helper"

class Webauthn::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "should get new" do
    get new_webauthn_session_url
    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["challenge"].present?
  end

  test "should clear challenge when credential not found" do
    get new_webauthn_session_url
    assert session[:authentication_challenge].present?

    random_id = Base64.urlsafe_encode64(SecureRandom.random_bytes(32))
    post webauthn_session_url, params: { id: random_id, rawId: random_id, type: "public-key", response: { clientDataJSON: "e30=", authenticatorData: "e30=", signature: "e30=", userHandle: "e30=" } }

    assert_response :unprocessable_entity
    assert_nil session[:authentication_challenge], "Challenge should be cleared even if credential is not found"
  end

  test "should not sign in unverified user" do
    unverified_user = users(:two)
    unverified_user.update!(email_verified_at: nil)

    credential = WebauthnCredential.create!(
      user: unverified_user,
      webauthn_id: "credential_id",
      public_key: "public_key",
      sign_count: 0
    )

    encoded_id = Base64.urlsafe_encode64("credential_id")

    # Mock the WebAuthn verification using a plain object to avoid Minitest::Mock kwargs issues
    mock_credential = Object.new
    def mock_credential.id; "credential_id"; end
    def mock_credential.sign_count; 1; end
    def mock_credential.verify(*args, **kwargs); true; end

    WebAuthn::Credential.stub :from_get, mock_credential do
      post webauthn_session_url, params: { id: encoded_id, rawId: encoded_id, type: "public-key", response: { clientDataJSON: "e30=", authenticatorData: "e30=", signature: "e30=", userHandle: "e30=" } }
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "error", json_response["status"]
    assert_includes json_response["message"], I18n.t("users.sessions.new.email_not_verified")
  end

  test "should accept invitation during sign-in" do
    user = users(:two)
    user.update!(email_verified_at: Time.current)
    inviter = users(:one)
    creative = Creative.create!(user: inviter, description: "Invite Test")
    invitation = Invitation.create!(inviter: inviter, creative: creative, permission: :read)
    token = invitation.generate_token_for(:invite)

    credential = WebauthnCredential.create!(
      user: user,
      webauthn_id: "credential_id_2",
      public_key: "public_key",
      sign_count: 0
    )
    encoded_id = Base64.urlsafe_encode64("credential_id_2")

    mock_credential = Object.new
    def mock_credential.id; "credential_id_2"; end
    def mock_credential.sign_count; 1; end
    def mock_credential.verify(*args, **kwargs); true; end

    WebAuthn::Credential.stub :from_get, mock_credential do
      post webauthn_session_url, params: {
        id: encoded_id,
        rawId: encoded_id,
        type: "public-key",
        response: { clientDataJSON: "e30=", authenticatorData: "e30=", signature: "e30=", userHandle: "e30=" },
        invite_token: token
      }
    end

    assert_response :ok
    assert invitation.reload.accepted_at, "Invitation should be accepted after sign-in with token"
  end
end
