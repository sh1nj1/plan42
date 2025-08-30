require 'rails_helper'
require 'ostruct'

RSpec.describe 'Creative shares linked creatives', type: :request do
  let(:owner) { User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner') }
  let(:shared_user) { User.create!(email: 'shared@example.com', password: 'pw', name: 'Shared') }
  let(:parent) { Creative.create!(user: owner, description: 'Parent') }
  let(:child) { Creative.create!(user: owner, parent: parent, description: 'Child') }

  before do
    allow_any_instance_of(CreativeSharesController).to receive(:require_authentication).and_return(true)
    Current.session = OpenStruct.new(user: owner)
    CreativeShare.create!(creative: parent, user: shared_user, permission: :read)
    parent.create_linked_creative_for_user(shared_user)
  end

  it 'does not create a linked creative when parent already shared' do
    post "/creatives/#{child.id}/creative_shares", params: { creative_id: child.id, user_email: shared_user.email, permission: :write }
    expect(response).to redirect_to(creatives_path)
    expect(Creative.find_by(origin_id: child.id, user_id: shared_user.id)).to be_nil
    share = CreativeShare.find_by(creative: child, user: shared_user)
    expect(share.permission).to eq('write')
  end
end
