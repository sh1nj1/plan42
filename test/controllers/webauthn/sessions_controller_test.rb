require "test_helper"

class Webauthn::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "should get new" do
    get new_webauthn_session_url
    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["challenge"].present?
  end
end
