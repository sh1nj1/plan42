require 'rails_helper'
require 'ostruct'

RSpec.describe 'Comment show redirect', type: :request do
  let(:user) { User.create!(email: 'user2@example.com', password: 'pw', name: 'User2') }
  let(:creative) { Creative.create!(user: user, description: 'Creative with comments') }
  let!(:comment) { creative.comments.create!(user: user, content: 'My comment') }

  before do
    allow_any_instance_of(CommentsController).to receive(:require_authentication).and_return(true)
    Current.session = OpenStruct.new(user: user)
  end

  it 'redirects to creatives index with comment_id param' do
    get "/creatives/#{creative.id}/comments/#{comment.id}"
    expect(response).to redirect_to("/creatives?id=#{creative.id}&comment_id=#{comment.id}")
  end
end
