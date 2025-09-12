module SystemHelpers
  PASSWORD = 'P4ssW0rd!'

  def sign_in(user)
    visit new_session_path
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: user.email
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: PASSWORD
    find('#sign-in-submit').click
    wait_for_path(root_path)
  end
end
