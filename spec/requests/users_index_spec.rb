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
end
