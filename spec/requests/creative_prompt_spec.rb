require 'rails_helper'

RSpec.describe 'Creative prompt in JSON', type: :request do
  let(:user) { User.create!(email: 'user@example.com', password: 'pw', name: 'User') }
  let(:creative) { Creative.create!(user: user, description: 'Slide') }

  before do
    allow_any_instance_of(CreativesController).to receive(:require_authentication).and_return(true)
    allow(Current).to receive(:user).and_return(user)
  end

  it 'includes prompt field' do
    creative.comments.create!(user: user, content: '> Hello presenter', private: true)
    get "/creatives/#{creative.id}.json"
    expect(response).to have_http_status(:success)
    data = JSON.parse(response.body)
    expect(data['prompt']).to eq('Hello presenter')
  end
end
