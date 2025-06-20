require 'rails_helper'
require 'ostruct'

RSpec.describe Comment, type: :model do
  it 'defaults user to Current.user on create' do
    owner = User.create!(email: 'creative_owner@example.com', password: 'pw')
    user = User.create!(email: 'test@example.com', password: 'pw')
    Current.session = OpenStruct.new(user: user)
    creative = Creative.create!(user: owner, description: 'creative')

    comment = Comment.create!(creative: creative, content: 'hi')
    expect(comment.user).to eq(user)
  end
end
