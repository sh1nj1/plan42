require "test_helper"

class DevicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Device.delete_all
  end

  test "creating a device with an existing token updates the record" do
    original_user = users(:one)
    current_user = users(:two)

    device = Device.create!(
      user: original_user,
      client_id: "existing-client",
      device_type: :web,
      app_id: "com.example.app",
      app_version: "1.0.0",
      fcm_token: "shared-token"
    )

    login_as(current_user)

    post collavre.devices_path, params: {
      device: {
        client_id: "updated-client",
        device_type: "web",
        app_id: "com.example.app.updated",
        app_version: "2.0.0",
        fcm_token: "shared-token"
      }
    }

    assert_response :no_content

    device.reload
    assert_equal current_user.id, device.user.id
    assert_equal "updated-client", device.client_id
    assert_equal "com.example.app.updated", device.app_id
    assert_equal "2.0.0", device.app_version
    assert_equal 1, Device.where(fcm_token: "shared-token").count
  end

  private

  def login_as(user)
    user.update!(email_verified_at: Time.current)
    post session_path, params: { email: user.email, password: "password" }
  end
end
