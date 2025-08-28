require 'rails_helper'

RSpec.describe 'Session timezone', type: :request do
  let!(:user) { User.create!(email: 'user@example.com', password: 'pw', name: 'User', email_verified_at: Time.current) }

  it 'stores timezone on login' do
    post session_path, params: { email: user.email, password: 'pw', timezone: 'Asia/Tokyo' }
    expect(response).to redirect_to(root_url)
    expect(user.reload.timezone).to eq('Asia/Tokyo')
  end
end
