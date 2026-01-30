ENV["RAILS_ENV"] ||= "test"
require_relative "../../../test/test_helper"
require "collavre_slack"

module CollavreSlackTestHelpers
  def create_user(email: "user@example.com", name: "Test User")
    Collavre.user_class.create!(
      email: email,
      name: name,
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
  end

  def create_creative(user)
    Collavre::Creative.create!(
      description: "Slack test creative",
      progress: 0.0,
      user: user
    )
  end
end

class ActiveSupport::TestCase
  include CollavreSlackTestHelpers
end

class ActionDispatch::SystemTestCase
  include CollavreSlackTestHelpers
end
