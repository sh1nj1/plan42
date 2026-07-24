# frozen_string_literal: true

# Configure Rails environment
ENV["RAILS_ENV"] ||= "test"

# Load the host application for testing
# This allows engine tests to run against the full application stack
require_relative "../../../test/support/coverage" # no-op unless COVERAGE is set; must precede app code
require_relative "../../../config/environment"
require "rails/test_help"
require "minitest/mock"

# The `collavre` test helper (below) exposes the bare
# `Collavre::Engine.routes.url_helpers` module, which has no request context.
# Its `*_url` helpers take the route set's optimized generation path, whose host
# comes from the engine route set's `default_url_options` — empty by default in
# test. Without a host these calls raise "Missing host to link to!" once any test
# has warmed the optimized path (order-dependent). Seed the engine host so `_url`
# helpers resolve regardless of suite ordering. Scoped to the engine route set
# only; the app route host stays unset to preserve the OpenRedirect guard in
# config/application.rb.
Collavre::Engine.routes.default_url_options[:host] ||= "www.example.com"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    if ENV["COVERAGE"]
      parallelize_setup do |worker|
        SimpleCov.command_name "#{SimpleCov.command_name}-#{worker}"
      end
      parallelize_teardown do |_worker|
        SimpleCov.result
      end
    end

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
