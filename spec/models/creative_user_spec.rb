require 'rails_helper'
require 'ostruct'

RSpec.describe Creative, type: :model do
  let(:owner) do
    user = User.create!(email: 'owner@example.com', password: 'pw')
    Current.session = OpenStruct.new(user: user)
    user
  end

  before do
    Current.session = OpenStruct.new(user: owner)
  end

  it 'assigns parent user when parent_id is present' do
    parent = Creative.create!(user: owner, description: 'Parent')
    other_user = User.create!(email: 'other@example.com', password: 'pw')
    Current.session = OpenStruct.new(user: other_user)
    child = Creative.create!(parent: parent, description: 'Child')
    expect(child.user).to eq(parent.user)
  end

  it 'assigns Current.user when parent is nil' do
    creative = Creative.create!(description: 'Root')
    expect(creative.user).to eq(owner)
  end
end
