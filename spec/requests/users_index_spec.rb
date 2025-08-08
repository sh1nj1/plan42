require 'rails_helper'

RSpec.describe 'Users index', type: :request do
  before do
    allow_any_instance_of(UsersController).to receive(:require_authentication).and_return(true)
  end

  it 'displays user email' do
    user = User.create!(email: 'test@example.com', password: 'pw', name: 'Test User')
    get users_path
    expect(response.body).to include(user.email)
  end

  it 'shows last login time and avatar state' do
    # Count existing inactive users before creating new ones
    initial_inactive_count = User.joins("LEFT JOIN sessions ON users.id = sessions.user_id")
                                .where(sessions: { id: nil })
                                .count

    active = User.create!(email: 'active@example.com', password: 'pw', name: 'Active User')
    session = active.sessions.create!(ip_address: '127.0.0.1', user_agent: 'test')
    _inactive = User.create!(email: 'inactive@example.com', password: 'pw', name: 'Inactive User')

    get users_path

    expect(response.body).to include(I18n.l(session.created_at, format: :short))
    # Expect the initial inactive count + 1 (the new inactive user we created)
    expect(response.body.scan('comment-presence-avatar inactive').size).to eq(initial_inactive_count + 1)
  end
end
