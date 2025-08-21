require 'rails_helper'

RSpec.describe 'Creatives access for anonymous users', type: :request do
  it 'shows creatives shared with the Anonymous user' do
    owner = User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner')
    creative = Creative.create!(user: owner, description: 'Anonymous viewable')
    CreativeShare.create!(creative: creative, user: User.anonymous, permission: :read)
    creative.create_linked_creative_for_user(User.anonymous)

    get creatives_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Anonymous viewable')
  end
end
