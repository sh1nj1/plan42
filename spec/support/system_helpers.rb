module SystemHelpers
  PASSWORD = 'P4ssW0rd!'

  def sign_in(user)
    visit new_session_path
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: user.email
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: PASSWORD
    find('#sign-in-submit').click
    expect(page).to have_current_path(root_path, ignore_query: true)
  end
end
