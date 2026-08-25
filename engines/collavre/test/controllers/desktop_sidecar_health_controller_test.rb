# frozen_string_literal: true

require "test_helper"

class DesktopSidecarHealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_secret = ENV["COLLAVRE_DESKTOP_SIDECAR_SECRET"]
    @secret = "desktop-sidecar-test-secret"
    ENV["COLLAVRE_DESKTOP_SIDECAR_SECRET"] = @secret
  end

  teardown do
    ENV["COLLAVRE_DESKTOP_SIDECAR_SECRET"] = @previous_secret
  end

  test "returns an HMAC proof for the native sidecar challenge" do
    challenge = "native-challenge"

    get collavre.desktop_setup_sidecar_health_path, params: { challenge: challenge }

    assert_response :success
    expected = Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", @secret, challenge), padding: false)
    assert_equal expected, response.body
  end

  test "rejects remote sidecar health requests" do
    get collavre.desktop_setup_sidecar_health_path,
        params: { challenge: "native-challenge" },
        headers: { "REMOTE_ADDR" => "10.0.0.25" }

    assert_response :forbidden
  end
end
