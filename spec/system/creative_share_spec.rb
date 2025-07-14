require 'rails_helper'

RSpec.describe 'Creative 공유 리스트', type: :system do
  let!(:user) { User.create!(email: 'user1@example.com', password: 'password', name: 'User1', email_verified_at: Time.now) }
  let!(:creative) { Creative.create!(description: '테스트', user: user) }
  let!(:share) { CreativeShare.create!(creative: creative, user: user, permission: 'read') }

  def resize_window_to_pc
    page.current_window.resize_to(1200, 800)
  rescue Capybara::NotSupportedByDriverError
    # ignore if driver does not support resizing
  end

  it '공유 리스트가 정상적으로 표시된다' do
    resize_window_to_pc
    visit new_session_path
    expect(page).not_to have_field(placeholder: I18n.t('users.new.enter_your_name'))
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: user.email
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: 'password'
    find('#sign-in-submit').click
    expect(page).not_to have_content(I18n.t('users.sessions.new.try_another_email_or_password'))
    visit creative_path(creative)
    expect(page).to have_css('#share-creative-modal', text: I18n.t('creatives.index.shared_with'), visible: :all)
    expect(page).to have_css('#share-creative-modal', text: 'User1', visible: :all)
    expect(page).to have_css('#share-creative-modal', text: 'Read', visible: :all)
  end
end
