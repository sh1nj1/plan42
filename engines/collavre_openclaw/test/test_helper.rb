require_relative "../../../test/support/coverage" # no-op unless COVERAGE is set; must precede app code
require "minitest/autorun"
require "rails"
require "active_support/test_case"

# Load the engine
require "collavre_openclaw"

class ActiveSupport::TestCase
  # Add helper methods for all tests here
end
