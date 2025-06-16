require 'rails_helper'

RSpec.describe 'Creative 공유 리스트', type: :system do
  let!(:user) { User.create!(email: 'user1@example.com', password: 'password', email_verified_at: Time.now) }
  let!(:creative) { Creative.create!(description: '테스트', user: user) }
  let!(:share) { CreativeShare.create!(creative: creative, user: user, permission: 'read') }

  it '공유 리스트가 정상적으로 표시된다' do
    visit new_session_path
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: user.email
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: 'password'
    click_button I18n.t('app.sign_in')
    expect(page).not_to have_content(I18n.t('users.sessions.new.try_another_email_or_password'))
    visit creative_path(creative)
    click_button I18n.t('creatives.index.share')
    expect(page).to have_content(I18n.t('creatives.index.shared_with'))
    expect(page).to have_content('user1@example.com')
    expect(page).to have_content("user1@example.com\nRead")
  end
end
