ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

# Add engines test directories to the test runner
# Manually require engine tests to ensure they run with `bin/rails test`
Dir.glob(Rails.root.join("engines/*/test/**/*_test.rb")).each do |f|
  require f
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    setup do
      Rails.cache.clear
      Current.reset
      # Rebuild the closure tree for Creatives fixture
      Creative.rebuild! if defined?(Creative)
    end
  end
end

module IntegrationAuthHelper
  def sign_in_as(user, password: "pw", follow_redirect: false)
    user.update!(email_verified_at: Time.current) unless user.email_verified?
    post session_path, params: { email: user.email, password: password }
    assert_response :redirect
    follow_redirect! if follow_redirect && response.redirect?
  end

  def sign_out
    delete session_path
  end
end

class ActionDispatch::IntegrationTest
  include IntegrationAuthHelper
end
