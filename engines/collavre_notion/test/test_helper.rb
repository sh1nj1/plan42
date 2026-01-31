ENV["RAILS_ENV"] ||= "test"
require_relative "../../../test/test_helper"
require "collavre_notion"

module CollavreNotionTestHelpers
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
      description: "Notion test creative",
      progress: 0.0,
      user: user
    )
  end
end

class ActiveSupport::TestCase
  include CollavreNotionTestHelpers
end

class ActionDispatch::IntegrationTest
  # Notion engine routes - use notion_engine.path_helper for Notion-specific routes
  def notion_engine
    CollavreNotion::Engine.routes.url_helpers
  end
end

class ActionDispatch::SystemTestCase
  include CollavreNotionTestHelpers
end
