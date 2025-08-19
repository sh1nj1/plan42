require 'rails_helper'

RSpec.describe 'Google authentication', type: :request do
  describe 'POST /auth/google_oauth2/callback' do
    before { OmniAuth.config.test_mode = true }
    after do
      OmniAuth.config.mock_auth[:google_oauth2] = nil
      OmniAuth.config.test_mode = false
    end

    it 'sets avatar_url from Google when user lacks avatar' do
      image_url = 'https://example.com/avatar.jpg'
      auth_hash = OmniAuth::AuthHash.new(
        provider: 'google_oauth2',
        uid: '12345',
        info: OmniAuth::AuthHash.new(
          email: 'user@example.com',
          name: 'Test User',
          image: image_url
        )
      )

      OmniAuth.config.mock_auth[:google_oauth2] = auth_hash

      post '/auth/google_oauth2/callback'

      user = User.last
      expect(user.avatar_url).to eq(image_url)
      expect(user.avatar).not_to be_attached
    end
  end
end
