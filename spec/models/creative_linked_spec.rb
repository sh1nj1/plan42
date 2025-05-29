require 'rails_helper'
require 'ostruct'

RSpec.describe 'Linked Creative', type: :model do

  let(:owner) { user = User.create!(email_address: 'owner@example.com', password: 'pw')
    Current.session = OpenStruct.new(user: user)
    user
  }
  let(:shared_user) { User.create!(email_address: 'shared@example.com', password: 'pw') }
  let(:parent) { Creative.create!(user: owner, description: 'Parent') }
  let(:creative) { Creative.create!(user: owner, parent: parent, description: 'Original', progress: 1.0) }

  describe '생성 및 공유' do
    it 'CreativeShare 생성 시 Linked Creative가 자동 생성된다' do
      expect {
        CreativeShare.create!(creative: creative, user: shared_user, permission: :read)
      }.to change { Creative.where(origin_id: creative.id, user_id: shared_user.id).count }.by(1)
    end

    it '이미 Linked Creative가 있으면 중복 생성하지 않는다' do
      CreativeShare.create!(creative: creative, user: shared_user, permission: :read)
      expect {
        CreativeShare.create!(creative: creative, user: shared_user, permission: :read)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe 'Linked Creative 속성 및 참조' do
    let!(:share) { CreativeShare.create!(creative: creative, user: shared_user, permission: :read) }
    let(:linked) { Creative.find_by(origin_id: creative.id, user_id: shared_user.id) }

    it 'Linked Creative는 origin의 description/progress/user를 참조한다' do
      expect(linked.effective_description).to eq creative.rich_text_description&.body&.to_s
      expect(linked.progress).to eq creative.progress
      expect(linked.user_id).to eq shared_user.id
      expect(linked.origin).to eq creative
    end

    it 'Linked Creative의 parent는 자신만의 parent를 가진다' do
      expect(linked.parent_id).to eq linked[:parent_id]
    end

    it 'children_with_permission은 origin의 children 중 권한 있는 것만 반환한다' do
      child = Creative.create!(user: owner, parent: creative, description: 'child', progress: 0.7)
      expect(linked.children_with_permission(shared_user)).to eq []
      CreativeShare.create!(creative: child, user: shared_user, permission: :read)
      expect(linked.children_with_permission(shared_user)).to include(child)
    end
  end

  describe 'progress 갱신' do

    it 'progress 갱신' do
      creative.update!(progress: 0.3)
      expect(creative.progress).to eq 0.3
    end
  end

  describe 'progress 연쇄 갱신' do
    let!(:share) { CreativeShare.create!(creative: creative, user: shared_user, permission: :read) }
    let!(:linked) { Creative.find_by(origin_id: creative.id, user_id: shared_user.id) }

    it 'Linked Creative의 progress가 바뀌면 origin 및 parent의 progress도 갱신된다' do
      expect(linked.progress).to eq 1.0
      creative.update!(progress: 0.3)
      parent.reload
      expect(creative.progress).to eq 0.3
      expect(linked.reload.progress).to eq 0.3
      expect(creative.progress).to eq linked.progress
      expect(parent.progress).to eq 0.3
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
      expect(creative.has_permission?(User.new(email_address: 'other@example.com', password: 'pw'))).to be false
    end
  end

end
