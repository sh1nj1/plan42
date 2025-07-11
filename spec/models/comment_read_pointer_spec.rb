require 'rails_helper'

RSpec.describe CommentReadPointer, type: :model do
  it 'enforces user and creative uniqueness' do
    user = User.create!(email: 'user@example.com', password: 'pw', name: 'User')
    creative = Creative.create!(user: user, description: 'c')
    CommentReadPointer.create!(user: user, creative: creative)

    dup = CommentReadPointer.new(user: user, creative: creative)
    expect(dup.valid?).to be false
  end
end
