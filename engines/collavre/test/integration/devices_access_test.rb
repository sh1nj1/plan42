require "test_helper"

class DevicesAccessTest < ActionDispatch::IntegrationTest
  test "unauthenticated device create does not store return location" do
    post collavre.devices_path, params: { device: { client_id: "abc", device_type: "browser" } }
    assert_redirected_to new_session_path
    assert_nil session[:return_to_after_authenticating]
  end
end
