require 'rails_helper'
require 'ostruct'

RSpec.describe 'Linked Creative', type: :model do
  let(:owner) { user = User.create!(email: 'owner@example.com', password: 'pw', name: 'Owner')
    Current.session = OpenStruct.new(user: user)
    user
  }
  let(:shared_user) { User.create!(email: 'shared@example.com', password: 'pw', name: 'Shared') }
  let(:parent) { Creative.create!(user: owner, description: 'Parent') }
  let(:creative) { Creative.create!(user: owner, parent: parent, description: 'Original', progress: 1.0) }

  describe '생성 및 공유' do
    it '이미 Linked Creative가 있으면 중복 생성하지 않는다' do
      CreativeShare.create!(creative: creative, user: shared_user, permission: :read)
      expect {
        CreativeShare.create!(creative: creative, user: shared_user, permission: :read)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe 'progress 갱신' do
    it 'progress 갱신' do
      creative.update!(progress: 0.3)
      expect(creative.progress).to eq 0.3
    end
  end

  describe '삭제 동작' do
    let!(:share) { CreativeShare.create!(creative: creative, user: shared_user, permission: :read) }
    let!(:linked) { Creative.find_by(origin_id: creative.id, user_id: shared_user.id) }

    it 'origin Creative가 삭제되면 Linked Creative도 함께 삭제된다' do
      expect { creative.destroy }.not_to raise_error
      expect(Creative.where(origin_id: creative.id)).to be_empty
    end
  end

  describe '권한' do
    let!(:share) { CreativeShare.create!(creative: creative, user: shared_user, permission: :read) }
    let(:linked) { Creative.find_by(origin_id: creative.id, user_id: shared_user.id) }

    it 'owner 또는 CreativeShare가 있으면 has_permission?이 true' do
      expect(creative.has_permission?(owner)).to be true
      expect(creative.has_permission?(shared_user)).to be true
      expect(creative.has_permission?(User.new(email: 'other@example.com', password: 'pw', name: 'Other'))).to be false
    end
  end
end
