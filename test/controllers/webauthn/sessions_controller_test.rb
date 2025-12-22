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
end
