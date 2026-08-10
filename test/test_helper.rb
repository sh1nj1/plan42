ENV["RAILS_ENV"] ||= "test"
require_relative "support/coverage" # no-op unless COVERAGE is set; must precede app code
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

# Engine `*_url` helpers (via the bare Collavre::Engine.routes.url_helpers module
# used across tests) take the route set's optimized generation path, whose host
# comes from the engine route set's default_url_options — empty by default in
# test. Seed it so those helpers resolve a host regardless of suite ordering.
# Engine route set only; app route host stays unset (OpenRedirect guard).
Collavre::Engine.routes.default_url_options[:host] ||= "www.example.com"

# Add engines test directories to the test runner
# Note: We do not auto-load engine tests here to avoid running them during targeted app tests.
# Use `rails test engines/` or `rake test:engines` to run engine tests.

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    if ENV["COVERAGE"]
      # Give each forked worker its own SimpleCov command name and flush its
      # result so the primary process can merge them into one report.
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

    # The navigation registry is a process-wide singleton seeded once by the
    # engine initializer. A test that resets it without restoring leaves every
    # later test in the same process rendering an empty GNB, which surfaces as
    # unrelated view assertions failing under some seeds. Fail on the test that
    # emptied it instead of on its victims.
    # Raises rather than asserts so the guard does not add an assertion to every
    # test in the suite, which would hide the "missing assertions" reporter.
    teardown do
      next unless defined?(Navigation::Registry)
      next if Navigation::Registry.instance.all.any?

      raise("Navigation::Registry was left empty by this test. " \
      "Snapshot it with `.all` in setup and re-register the items in teardown.")
    end
  end
end

TEST_PASSWORD = "password123"

module IntegrationAuthHelper
  def sign_in_as(user, password: TEST_PASSWORD, follow_redirect: false)
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
  include Collavre::Engine.routes.url_helpers

  # CollavrePlan engine routes — mounted at "/", paths are /plans, /creative_plan etc.
  def collavre_plan_engine
    CollavrePlan::Engine.routes.url_helpers
  end

  # Helper to access main app routes when needed
  def main_app
    Rails.application.routes.url_helpers
  end
end
