require 'rails_helper'

RSpec.describe 'Creative 공유 리스트', type: :system do
  let!(:user) { User.create!(email: 'user1@example.com', password: 'password', name: 'User1', email_verified_at: Time.now) }
  let!(:creative) { Creative.create!(description: '테스트', user: user) }
  let!(:share) { CreativeShare.create!(creative: creative, user: user, permission: 'read') }

  it '공유 리스트가 정상적으로 표시된다' do
    sign_in(user)
    visit creative_path(creative)
    expect(page).to have_css('#share-creative-modal', text: I18n.t('creatives.index.shared_with'), visible: :all)
    expect(page).to have_css('#share-creative-modal', text: 'User1', visible: :all)
    expect(page).to have_css('#share-creative-modal', text: 'Read', visible: :all)
  end
end
