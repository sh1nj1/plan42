module SystemLoginHelper
  def resize_window_to_pc
    page.current_window.resize_to(1200, 800)
  rescue Capybara::NotSupportedByDriverError
  end

  def sign_in(user, password: 'password')
    resize_window_to_pc
    visit new_session_path
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: user.email
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: password
    find('#sign-in-submit').click
    allow_push_notifications
  end

  private

  def allow_push_notifications
    find('#allow-notifications').click if page.has_css?('#allow-notifications', wait: 1)
  end
end

RSpec.configure do |config|
  config.include SystemLoginHelper, type: :system
end
