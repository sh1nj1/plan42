require 'rails_helper'
require 'ostruct'

RSpec.describe 'Creative share permissions', type: :request do
  let(:owner) { User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner') }
  let(:writer) { User.create!(email: 'writer@example.com', password: 'pw', name: 'Writer') }
  let(:admin_user) { User.create!(email: 'admin@example.com', password: 'pw', name: 'Admin') }
  let(:other) { User.create!(email: 'other@example.com', password: 'pw', name: 'Other') }
  let(:creative) { Creative.create!(user: owner, description: 'Root') }

  before do
    allow_any_instance_of(CreativeSharesController).to receive(:require_authentication).and_return(true)
  end

  context 'writer permission' do
    before do
      CreativeShare.create!(creative: creative, user: writer, permission: :write)
      Current.session = OpenStruct.new(user: writer)
    end

    it 'cannot create or destroy shares' do
      post creative_creative_shares_path(creative), params: { user_email: other.email, permission: :read }
      expect(CreativeShare.find_by(creative: creative, user: other)).to be_nil

      share = CreativeShare.create!(creative: creative, user: other, permission: :read)
      delete creative_creative_share_path(creative, share)
      expect(CreativeShare.exists?(share.id)).to be true
    end
  end

  context 'admin permission' do
    before do
      CreativeShare.create!(creative: creative, user: admin_user, permission: :admin)
      Current.session = OpenStruct.new(user: admin_user)
    end

    it 'can create and destroy shares' do
      post creative_creative_shares_path(creative), params: { user_email: other.email, permission: :read }
      share = CreativeShare.find_by(creative: creative, user: other)
      expect(share).to be_present

      delete creative_creative_share_path(creative, share)
      expect(CreativeShare.exists?(share.id)).to be false
    end
  end
end
