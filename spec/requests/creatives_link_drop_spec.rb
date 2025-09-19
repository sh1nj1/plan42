require 'rails_helper'
require 'ostruct'

RSpec.describe 'Creative link drop', type: :request do
  let(:user) { User.create!(email: 'user@example.com', password: 'pw', name: 'User') }
  let!(:root) { Creative.create!(user: user, description: 'Root', progress: 0.5, sequence: 0) }
  let!(:target_sibling) { Creative.create!(user: user, parent: root, description: 'Target', sequence: 0, progress: 0.2) }
  let!(:dragged) { Creative.create!(user: user, parent: root, description: 'Dragged', sequence: 1, progress: 0.3) }
  let!(:dragged_child) { Creative.create!(user: user, parent: dragged, description: 'Child of dragged', progress: 0.1) }

  before do
    allow_any_instance_of(CreativesController).to receive(:require_authentication).and_return(true)
    Current.session = OpenStruct.new(user: user)
  end

  it 'creates a linked creative as child when direction is child' do
    post '/creatives/link_drop', params: {
      dragged_id: dragged.id,
      target_id: target_sibling.id,
      direction: 'child'
    }, as: :json

    expect(response).to have_http_status(:ok)
    parsed = JSON.parse(response.body)
    expect(parsed['creative_id']).to be_present
    linked = Creative.find(parsed['creative_id'])
    expect(linked.origin_id).to eq(dragged.id)
    expect(linked.parent_id).to eq(target_sibling.id)
    # linked creative should reflect origin children via has_children
    expect(parsed['html']).to include('creative-tree')
    expect(parsed['html']).to include("has-children")
  end

  it 'inserts linked creative before target when direction is up' do
    other = Creative.create!(user: user, parent: root, description: 'Other', sequence: 2, progress: 0.4)

    post '/creatives/link_drop', params: {
      dragged_id: dragged.id,
      target_id: other.id,
      direction: 'up'
    }, as: :json

    expect(response).to have_http_status(:ok)
    linked = Creative.find(JSON.parse(response.body)['creative_id'])
    expect(linked.parent_id).to eq(root.id)
    ordered = root.children.order(:sequence).pluck(:id)
    expect(ordered).to include(linked.id)
    linked_index = ordered.index(linked.id)
    other_index = ordered.index(other.id)
    expect(linked_index).to be < other_index
  end

  it 'returns 422 for invalid parameters' do
    post '/creatives/link_drop', params: { dragged_id: 0, target_id: 0, direction: 'up' }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
