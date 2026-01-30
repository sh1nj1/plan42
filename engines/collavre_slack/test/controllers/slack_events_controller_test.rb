require_relative "../test_helper"

module CollavreSlack
  class SlackEventsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @routes = CollavreSlack::Engine.routes
      CollavreSlack.config.signing_secret = "secret"
    end

    test "responds to url verification" do
      payload = { type: "url_verification", challenge: "abc123" }
      body = payload.to_json
      timestamp = Time.now.to_i.to_s
      signature = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", CollavreSlack.config.signing_secret, "v0:#{timestamp}:#{body}")

      post CollavreSlack::Engine.routes.url_helpers.slack_events_path,
           params: body,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "X-Slack-Request-Timestamp" => timestamp,
             "X-Slack-Signature" => signature
           }

      assert_response :success
      assert_equal({ "challenge" => "abc123" }, JSON.parse(response.body))
    end
  end
end
