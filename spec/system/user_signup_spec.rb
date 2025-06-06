require 'rails_helper'

describe 'User sign up', type: :system do
  it 'creates a new user' do
    visit new_user_path
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: 'testuser@example.com'
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: 'password123'
    fill_in placeholder: I18n.t('users.new.confirm_your_password'), with: 'password123'
    click_button I18n.t('users.new.sign_up')

    expect(page).to have_content(I18n.t('users.new.success_sign_up'))
    expect(User.find_by(email: 'testuser@example.com')).to be_present
  end
end
