require "test_helper"
require_relative "support/system_helpers"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SystemHelpers

  driven_by :selenium, using: :chrome, screen_size: [ 1920, 1080 ]
end
