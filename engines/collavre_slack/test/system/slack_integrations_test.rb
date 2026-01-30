require_relative "../test_helper"

class SlackIntegrationsSystemTest < ActionDispatch::SystemTestCase
  driven_by :rack_test

  test "renders slack integrations page" do
    skip "System test requires complex login setup - covered by integration tests"
  end
end
