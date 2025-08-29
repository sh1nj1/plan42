require 'rails_helper'

RSpec.describe 'Share popup permissions', type: :system do
  let!(:owner) { User.create!(email: 'owner@example.com', password: 'password', name: 'Owner', email_verified_at: Time.now) }
  let!(:writer) { User.create!(email: 'writer@example.com', password: 'password', name: 'Writer', email_verified_at: Time.now) }
  let!(:creative) { Creative.create!(description: 'Test', user: owner) }

  def sign_in(email)
    visit new_session_path
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: email
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: 'password'
    find('#sign-in-submit').click
  end

  it 'writer can view but not modify shares' do
    CreativeShare.create!(creative: creative, user: writer, permission: :write)
    sign_in(writer.email)
    visit creative_path(creative)
    find('#share-creative-btn').click
    expect(page).to have_css('#share-creative-modal', visible: true)
    expect(page).not_to have_css('#share-creative-form', visible: :all)
  end
end
