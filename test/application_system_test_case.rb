require "test_helper"
require "capybara/rails"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Use HEADLESS=false to see the browser during tests
  driven_by :selenium,
    using: ENV["HEADLESS"] == "false" ? :chrome : :headless_chrome,
    screen_size: [ 1400, 1400 ]

  include IntegrationAuthHelper
  include Collavre::Engine.routes.url_helpers

  def sign_in_system(user, password: "password")
    visit collavre.new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: password
    find("#sign-in-submit").click
    # Wait for page to load after sign-in
    sleep 0.5
  end
end
