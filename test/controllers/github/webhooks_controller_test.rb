require "test_helper"
require "uri"

class Github::WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @account = GithubAccount.create!(
      user: @user,
      github_uid: "456",
      login: "webhook-user",
      name: "Webhook User",
      token: "webhook-token"
    )
    @link = GithubRepositoryLink.create!(
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

    Github::PullRequestProcessor.stub :new, ->(*) { processor } do
      post github_webhook_path,
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

  test "rejects webhook when signature does not match secret" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'wrong-secret', body)}"

    post github_webhook_path,
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

    Github::PullRequestProcessor.stub :new, ->(*) { processor } do
      post github_webhook_path,
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

    post github_webhook_path,
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "HTTP_X_HUB_SIGNATURE_256" => signature
         }

    assert_response :bad_request
  end
end
