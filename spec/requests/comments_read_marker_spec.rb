require 'rails_helper'
require 'ostruct'

RSpec.describe 'Comments read marker', type: :request do
  let(:user) { User.create!(email: 'user@example.com', password: 'pw', name: 'User') }
  let(:creative) { Creative.create!(user: user, description: 'Some creative') }

  before do
    allow_any_instance_of(CommentsController).to receive(:require_authentication).and_return(true)
    Current.session = OpenStruct.new(user: user)
  end

  it 'does not show last-read bar when pointer at latest comment' do
    creative.comments.create!(user: user, content: 'First')
    last = creative.comments.create!(user: user, content: 'Second')
    CommentReadPointer.create!(user: user, creative: creative, last_read_comment: last)
    get "/creatives/#{creative.id}/comments"
    expect(response.body).not_to include('last-read')
  end
end
