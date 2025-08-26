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
      expires_at = 1.hour.from_now.to_i
      auth_hash = OmniAuth::AuthHash.new(
        provider: 'google_oauth2',
        uid: '12345',
        info: OmniAuth::AuthHash.new(
          email: 'user@example.com',
          name: 'Test User',
          image: image_url
        ),
        credentials: OmniAuth::AuthHash.new(
          token: 'access-token',
          refresh_token: 'refresh-token',
          expires_at: expires_at
        )
      )

      OmniAuth.config.mock_auth[:google_oauth2] = auth_hash

      post '/auth/google_oauth2/callback'

      user = User.last
      expect(user.avatar_url).to eq(image_url)
      expect(user.avatar).not_to be_attached
    end

    it 'stores OAuth tokens' do
      expires_at = 1.hour.from_now.to_i
      auth_hash = OmniAuth::AuthHash.new(
        provider: 'google_oauth2',
        uid: '12345',
        info: OmniAuth::AuthHash.new(
          email: 'user@example.com',
          name: 'Test User'
        ),
        credentials: OmniAuth::AuthHash.new(
          token: 'token',
          refresh_token: 'refresh-token',
          expires_at: expires_at
        )
      )

      OmniAuth.config.mock_auth[:google_oauth2] = auth_hash

      post '/auth/google_oauth2/callback'

      user = User.last
      expect(user.google_uid).to eq('12345')
      expect(user.google_access_token).to eq('token')
      expect(user.google_refresh_token).to eq('refresh-token')
      expect(user.google_token_expires_at.to_i).to eq(expires_at)
    end
  end
end
