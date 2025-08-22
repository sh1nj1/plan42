require 'rails_helper'
require 'ostruct'

RSpec.describe Creative, type: :model do
  let(:owner) do
    user = User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner')
    Current.session = OpenStruct.new(user: user)
    user
  end
  let(:shared_user) { User.create!(email: 'shared@example.com', password: 'pw', name: 'Shared') }
  let!(:root) { Creative.create!(user: owner, description: 'Root') }
  let!(:child) { Creative.create!(user: owner, parent: root, description: 'Child') }
  let!(:grandchild) { Creative.create!(user: owner, parent: child, description: 'Grandchild') }

  after do
    Current.reset
  end

  it 'blocks permission when no_access is set on a descendant' do
    CreativeShare.create!(creative: root, user: shared_user, permission: :read)
    expect(child.has_permission?(shared_user, :read)).to be true

    CreativeShare.create!(creative: child, user: shared_user, permission: :no_access)
    expect(child.has_permission?(shared_user, :read)).to be false
    expect(grandchild.has_permission?(shared_user, :read)).to be false
  end

  it 'allows deeper node share overriding ancestor no_access' do
    CreativeShare.create!(creative: root, user: shared_user, permission: :read)
    CreativeShare.create!(creative: child, user: shared_user, permission: :no_access)
    CreativeShare.create!(creative: grandchild, user: shared_user, permission: :read)
    expect(grandchild.has_permission?(shared_user, :read)).to be true
  end
end
