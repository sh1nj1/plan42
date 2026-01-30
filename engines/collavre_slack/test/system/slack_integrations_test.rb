require "test_helper"

class SlackIntegrationsSystemTest < ActionDispatch::SystemTestCase
  driven_by :rack_test

  test "renders slack integrations page" do
    user = create_user(email: "system@example.com", name: "System User")
    creative = create_creative(user)

    visit CollavreSlack::Engine.routes.url_helpers.creative_slack_integrations_path(creative_id: creative.id)

    assert_text "Slack Integrations"
  end
end
