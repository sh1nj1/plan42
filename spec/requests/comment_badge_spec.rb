require 'rails_helper'
require 'ostruct'

RSpec.describe 'Comment badge', type: :request do
  let(:user) { User.create!(email: 'user@example.com', password: 'pw', name: 'User') }
  let(:creative) { Creative.create!(user: user, description: 'Some creative') }

  before do
    allow_any_instance_of(CreativesController).to receive(:require_authentication).and_return(true)
    Current.session = OpenStruct.new(user: user)
  end

  it 'renders unread comment count' do
    creative.comments.create!(user: user, content: 'First')
    get "/creatives/#{creative.id}/comment_badge"
    expect(response.body).to include('data-count="1"')
  end
end
