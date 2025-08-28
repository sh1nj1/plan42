require 'rails_helper'

RSpec.describe 'Session timezone', type: :request do
  let!(:user) { User.create!(email: 'user@example.com', password: 'pw', name: 'User', email_verified_at: Time.current) }

  it 'stores timezone on login' do
    post session_path, params: { email: user.email, password: 'pw', timezone: 'Asia/Tokyo' }
    expect(response).to redirect_to(root_url)
    expect(user.reload.timezone).to eq('Asia/Tokyo')
  end

  it 'allows clearing timezone from profile' do
    post session_path, params: { email: user.email, password: 'pw' }
    patch user_path(user), params: { user: { name: 'User', timezone: '' } }
    expect(response).to redirect_to(user_url(user))
    expect(user.reload.timezone).to be_nil
  end

  it 'accepts city names for timezone and stores canonical identifier' do
    post session_path, params: { email: user.email, password: 'pw' }
    patch user_path(user), params: { user: { name: 'User', timezone: 'Seoul' } }
    expect(response).to redirect_to(user_url(user))
    expect(user.reload.timezone).to eq('Asia/Seoul')
  end

  it 'preselects saved timezone on profile form' do
    user.update!(timezone: 'Asia/Seoul')
    post session_path, params: { email: user.email, password: 'pw' }
    get user_path(user)
    expect(response.body).to match(/option selected="selected" value="Asia\/Seoul"/)
  end
end
