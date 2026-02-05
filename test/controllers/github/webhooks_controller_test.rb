require "test_helper"
require "uri"

class CollavreGithub::WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @account = CollavreGithub::Account.create!(
      user: @user,
      github_uid: "456",
      login: "webhook-user",
      name: "Webhook User",
      token: "webhook-token"
    )
    @link = CollavreGithub::RepositoryLink.create!(
      creative: creatives(:tshirt),
      github_account: @account,
      repository_full_name: "webhook-user/example",
      webhook_secret: "existing-secret"
    )
    @payload = {
      "action" => "opened",
      "repository" => { "full_name" => @link.repository_full_name },
      "pull_request" => { "merged" => false, "title" => "Test", "number" => 1, "html_url" => "https://example.com" }
    }
  end

  test "accepts webhook when signature matches repository secret" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, body)}"
    processor = Minitest::Mock.new
    processor.expect(:call, true)

    CollavreGithub::PullRequestProcessor.stub :new, ->(*) { processor } do
      post "/github/webhook",
           params: body,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "HTTP_X_GITHUB_EVENT" => "pull_request",
             "HTTP_X_HUB_SIGNATURE_256" => signature
           }

      assert_response :success
    end

    processor.verify
  end

  test "dispatches system event with webhook details" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, body)}"

    processor = Minitest::Mock.new
    processor.expect(:call, true)

    dispatcher = Minitest::Mock.new
    dispatcher.expect :call, nil do |event_name, context|
      payload = context[:payload]

      event_name == "github_webhook" &&
        context[:event] == "pull_request" &&
        context[:action] == "opened" &&
        context[:repository] == @link.repository_full_name &&
        payload["action"] == "opened" &&
        payload.dig("repository", "full_name") == @link.repository_full_name
    end

    CollavreGithub::PullRequestProcessor.stub :new, ->(*) { processor } do
      Collavre::SystemEvents::Dispatcher.stub :dispatch, dispatcher do
        post "/github/webhook",
             params: body,
             headers: {
               "CONTENT_TYPE" => "application/json",
               "HTTP_X_GITHUB_EVENT" => "pull_request",
               "HTTP_X_HUB_SIGNATURE_256" => signature
             }
      end
    end

    assert_response :success

    processor.verify
    dispatcher.verify
  end

  test "dispatches system event with creative context from repository link" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, body)}"

    processor = Minitest::Mock.new
    processor.expect(:call, true)

    captured_context = nil
    dispatcher = ->(event_name, context) { captured_context = context }

    CollavreGithub::PullRequestProcessor.stub :new, ->(*) { processor } do
      Collavre::SystemEvents::Dispatcher.stub :dispatch, dispatcher do
        post "/github/webhook",
             params: body,
             headers: {
               "CONTENT_TYPE" => "application/json",
               "HTTP_X_GITHUB_EVENT" => "pull_request",
               "HTTP_X_HUB_SIGNATURE_256" => signature
             }
      end
    end

    assert_response :success
    processor.verify

    # Verify creative context is included
    assert_not_nil captured_context[:creative], "Creative context should be present"
    assert_equal @link.creative.id, captured_context[:creative][:id]
  end

  test "dispatches system event without creative when repository link not found" do
    # Use a different repository that doesn't have a link
    payload = @payload.merge("repository" => { "full_name" => "unknown/repo" })
    body = payload.to_json

    # Use fallback secret
    fallback_secret = "fallback-test-secret"
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', fallback_secret, body)}"

    captured_context = nil
    dispatcher = ->(event_name, context) { captured_context = context }

    Rails.application.stub :credentials, OpenStruct.new(github: { webhook_secret: fallback_secret }) do
      Collavre::SystemEvents::Dispatcher.stub :dispatch, dispatcher do
        post "/github/webhook",
             params: body,
             headers: {
               "CONTENT_TYPE" => "application/json",
               "HTTP_X_GITHUB_EVENT" => "push",
               "HTTP_X_HUB_SIGNATURE_256" => signature
             }
      end
    end

    assert_response :success

    # Creative context should not be present when no repository link
    assert_nil captured_context[:creative], "Creative context should not be present for unknown repo"
  end

  test "rejects webhook when signature does not match secret" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'wrong-secret', body)}"

    post "/github/webhook",
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "HTTP_X_GITHUB_EVENT" => "pull_request",
           "HTTP_X_HUB_SIGNATURE_256" => signature
         }

    assert_response :unauthorized
  end

  test "accepts webhook when payload is form encoded" do
    payload_json = @payload.to_json
    form_body = URI.encode_www_form(payload: payload_json)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, form_body)}"
    processor = Minitest::Mock.new
    processor.expect(:call, true)

    CollavreGithub::PullRequestProcessor.stub :new, ->(*) { processor } do
      post "/github/webhook",
           params: { payload: payload_json },
           headers: {
             "CONTENT_TYPE" => "application/x-www-form-urlencoded",
             "HTTP_X_GITHUB_EVENT" => "pull_request",
             "HTTP_X_HUB_SIGNATURE_256" => signature
           }

      assert_response :success
    end

    processor.verify
  end

  test "rejects webhook when event header missing" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, body)}"

    post "/github/webhook",
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "HTTP_X_HUB_SIGNATURE_256" => signature
         }

    assert_response :bad_request
  end
end
