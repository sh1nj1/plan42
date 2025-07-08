require 'rails_helper'
require 'ostruct'

RSpec.describe 'Linked Creative parent update', type: :request do
  let(:owner) { User.create!(email: 'owner@example.com', password: 'pw') }
  let(:shared_user) { User.create!(email: 'shared@example.com', password: 'pw') }
  let(:parent) { Creative.create!(user: owner, description: 'Parent') }
  let(:creative) { Creative.create!(user: owner, parent: parent, description: 'Original') }
  let(:new_parent) { Creative.create!(user: shared_user, description: 'New Parent') }

  before do
    allow_any_instance_of(CreativesController).to receive(:require_authentication).and_return(true)
    Current.session = OpenStruct.new(user: owner)
    CreativeShare.create!(creative: creative, user: shared_user, permission: :read)
    creative.create_linked_creative_for_user(shared_user)
    @linked = Creative.find_by(origin_id: creative.id, user_id: shared_user.id)
    Current.session = OpenStruct.new(user: shared_user)
  end

  it 'changes only the linked creative parent' do
    patch "/creatives/#{@linked.id}", params: { creative: { parent_id: new_parent.id } }
    expect(response).to redirect_to(@linked)
    @linked.reload
    creative.reload
    expect(@linked.parent).to eq new_parent
    expect(creative.parent).to eq parent
  end
end
