require "test_helper"

class GoogleAuthTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "sets avatar url when user lacks uploaded avatar" do
    image_url = "https://example.com/avatar.jpg"

    auth_hash = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "12345",
      info: OmniAuth::AuthHash.new(
        email: "user@example.com",
        name: "Test User",
        image: image_url
      ),
      credentials: OmniAuth::AuthHash.new(
        token: "test_token",
        refresh_token: "test_refresh_token",
        expires_at: Time.now.to_i + 3600
      )
    )

    OmniAuth.config.mock_auth[:google_oauth2] = auth_hash

    post "/auth/google_oauth2/callback"

    user = User.order(:created_at).last
    assert_equal image_url, user.avatar_url
    refute user.avatar.attached?
  end
end
