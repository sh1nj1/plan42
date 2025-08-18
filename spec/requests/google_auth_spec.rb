require 'rails_helper'
require 'stringio'

RSpec.describe 'Google authentication', type: :request do
  describe 'POST /auth/google_oauth2/callback' do
    before { OmniAuth.config.test_mode = true }
    after { OmniAuth.config.test_mode = false }

    it 'sets avatar from Google when user lacks avatar' do
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

      allow(URI).to receive(:open).with(image_url).and_return(StringIO.new('avatar'))

      post '/auth/google_oauth2/callback', env: { 'omniauth.auth' => auth_hash }

      user = User.last
      expect(user.avatar).to be_attached
    end
  end
end
