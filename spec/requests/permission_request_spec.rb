require 'rails_helper'
require 'ostruct'
require 'cgi'

RSpec.describe 'Permission request', type: :request do
  let(:owner) { User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner') }
  let(:requester) { User.create!(email: 'req@example.com', password: 'pw', name: 'Requester') }
  let(:creative) { Creative.create!(user: owner, description: 'Secret Creative Plan') }

  before do
    allow_any_instance_of(CreativesController).to receive(:require_authentication).and_return(true)
    Current = OpenStruct.new(user: requester)
  end

  it 'creates inbox item for owner' do
    post "/creatives/#{creative.id}/request_permission"
    expect(response).to have_http_status(:ok)
    item = InboxItem.last
    expect(item.owner).to eq owner
    expect(item.message).to include('Requester')
    expect(item.message).to include('Secret Creative Plan'.truncate(10))
    expect(item.link).to include("share_request=#{CGI.escape(requester.email)}")
  end
end
