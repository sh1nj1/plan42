require 'rails_helper'
require 'ostruct'

RSpec.describe 'Private comments', type: :request do
  let(:user1) { User.create!(email: 'user1@example.com', password: 'pw', name: 'User1') }
  let(:user2) { User.create!(email: 'user2@example.com', password: 'pw', name: 'User2') }
  let(:creative) { Creative.create!(user: user1, description: 'Some creative') }

  before do
    allow_any_instance_of(CommentsController).to receive(:require_authentication).and_return(true)
  end

  it 'only shows private comments to their author' do
    creative.comments.create!(user: user1, content: 'public')
    creative.comments.create!(user: user1, content: 'secret', private: true)

    allow(Current).to receive(:user).and_return(user1)
    get "/creatives/#{creative.id}/comments"
    expect(response.body).to include('public')
    expect(response.body).to include('secret')

    allow(Current).to receive(:user).and_return(user2)
    get "/creatives/#{creative.id}/comments"
    expect(response.body).to include('public')
    expect(response.body).not_to include('secret')
  end
end
