require 'rails_helper'
require 'ostruct'

describe Comment, type: :model do
  it 'creates inbox item for mentioned users' do
    owner = User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner')
    commenter = User.create!(email: 'commenter@example.com', password: 'pw', name: 'Commenter')
    mentioned = User.create!(email: 'mentioned@example.com', password: 'pw', name: 'Mentioned')
    creative = Creative.create!(user: owner, description: 'root')

    comment = Comment.create!(creative: creative, user: commenter, content: "hi @#{mentioned.email}")

    item = InboxItem.find_by(owner: mentioned)
    expect(item).not_to be_nil
    expect(item.message).to include(commenter.name)
  end
end
