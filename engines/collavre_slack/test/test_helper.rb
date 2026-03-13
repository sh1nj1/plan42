ENV["RAILS_ENV"] ||= "test"
require_relative "../../../test/test_helper"
require "collavre_slack"
require "webmock/minitest"
# Allow net connections by default so other engines' tests are not affected.
# collavre_slack tests rely on explicit stub_request() calls to intercept Slack API requests.
WebMock.allow_net_connect!

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

  # Stub Slack conversations.list with pagination support
  def stub_slack_channels(*pages, token: "xoxb-test-token")
    pages.each_with_index do |page, index|
      next_cursor = index < pages.size - 1 ? "cursor_page_#{index + 1}" : ""
      cursor_param = index == 0 ? nil : "cursor_page_#{index}"

      query = { "limit" => "200", "types" => "public_channel,private_channel" }
      query["cursor"] = cursor_param if cursor_param

      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including(query), headers: { "Authorization" => "Bearer #{token}" })
        .to_return(
          status: 200,
          body: {
            ok: true,
            channels: page,
            response_metadata: { next_cursor: next_cursor }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end
  end
end

class ActiveSupport::TestCase
  include CollavreSlackTestHelpers
end

class ActionDispatch::SystemTestCase
  include CollavreSlackTestHelpers
end
