require 'rails_helper'
require 'ostruct'

RSpec.describe 'Creative ancestor updates', type: :model do
  let(:user) { User.create!(email: 'owner1@example.com', password: 'pw') }

  before do
    Current.session = OpenStruct.new(user: user)
  end

  it 'updates ancestors when a new parent is inserted' do
    root = Creative.create!(user: user, description: 'Root')
    child = Creative.create!(user: user, parent: root, description: 'Child')

    new_parent = Creative.new(user: user, description: 'New Parent')
    new_parent.parent = root
    new_parent.save!

    child.update!(parent: new_parent)

    expect(new_parent.ancestor_ids).to eq [ root.id ]
    expect(child.ancestor_ids).to eq [ new_parent.id, root.id ]
  end
end
