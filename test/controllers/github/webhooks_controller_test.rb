require "test_helper"

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

  test "accepts issues webhook payload using fallback secret" do
    body = file_fixture("github_issue_opened_payload.json").read
    secret = "secret"
    previous_secret = ENV["GITHUB_WEBHOOK_SECRET"]
    ENV["GITHUB_WEBHOOK_SECRET"] = secret

    sha256_signature = OpenSSL::HMAC.hexdigest("SHA256", secret, body).upcase
    sha1_signature = OpenSSL::HMAC.hexdigest("SHA1", secret, body)

    post github_webhook_path,
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "HTTP_X_GITHUB_EVENT" => "issues",
           "HTTP_X_HUB_SIGNATURE_256" => "sha256=#{sha256_signature}",
           "HTTP_X_HUB_SIGNATURE" => "sha1=#{sha1_signature}"
         }

    assert_response :success
  ensure
    ENV["GITHUB_WEBHOOK_SECRET"] = previous_secret
  end
end
