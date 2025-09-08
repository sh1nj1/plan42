require 'rails_helper'
require 'ostruct'

describe Comment, type: :model do
  it 'creates a single inbox item for mentioned users' do
    owner = User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner')
    commenter = User.create!(email: 'commenter@example.com', password: 'pw', name: 'Commenter')
    mentioned = User.create!(email: 'mentioned@example.com', password: 'pw', name: 'Mentioned')
    creative = Creative.create!(user: owner, description: 'root')

    Comment.create!(creative: creative, user: commenter, content: "hi [@#{mentioned.name}](/users/#{mentioned.id})")

    items = InboxItem.where(owner: mentioned)
    expect(items.count).to eq(1)
    expect(items.first.message_key).to eq('inbox.user_mentioned')
    expect(items.first.localized_message).to include(commenter.name)
  end

  it 'does not create duplicate inbox items when mentioning an existing recipient' do
    owner = User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner')
    commenter = User.create!(email: 'commenter@example.com', password: 'pw', name: 'Commenter')
    creative = Creative.create!(user: owner, description: 'root')

    Comment.create!(creative: creative, user: commenter, content: "hi [@#{owner.name}](/users/#{owner.id})")

    items = InboxItem.where(owner: owner)
    expect(items.count).to eq(1)
    expect(items.first.message_key).to eq('inbox.user_mentioned')
  end
end
