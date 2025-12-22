require "test_helper"
require "webauthn/fake_client"

class Webauthn::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user, password: "password"
  end

  test "should get new" do
    get new_webauthn_registration_url
    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["challenge"].present?
    assert json_response["user"]["id"].present?
  end
end
