# frozen_string_literal: true

# Configure Rails environment
ENV["RAILS_ENV"] ||= "test"

# Load the host application for testing
# This allows engine tests to run against the full application stack
require_relative "../../../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper

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

TEST_PASSWORD = "password123"

module IntegrationAuthHelper
  def sign_in_as(user, password: TEST_PASSWORD, follow_redirect: false)
    user.update!(email_verified_at: Time.current) unless user.email_verified?
    post collavre.session_path, params: { email: user.email, password: password }
    assert_response :redirect
    follow_redirect! if follow_redirect && response.redirect?
  end

  def sign_out
    delete collavre.session_path
  end
end

class ActionDispatch::IntegrationTest
  include IntegrationAuthHelper
  include Collavre::Engine.routes.url_helpers

  # Helper to access engine routes
  def collavre
    Collavre::Engine.routes.url_helpers
  end

  # Helper to access main app routes
  def main_app
    Rails.application.routes.url_helpers
  end
end

# Configure ActionView::TestCase to include engine helpers
class ActionView::TestCase
  include Collavre::Engine.routes.url_helpers

  def collavre
    Collavre::Engine.routes.url_helpers
  end

  def main_app
    Rails.application.routes.url_helpers
  end
end
