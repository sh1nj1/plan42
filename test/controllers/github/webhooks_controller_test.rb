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
    @creative = creatives(:tshirt)
    @link = CollavreGithub::RepositoryLink.create!(
      creative: @creative,
      github_account: @account,
      repository_full_name: "webhook-user/example",
      webhook_secret: "existing-secret"
    )
    @payload = {
      "action" => "opened",
      "repository" => { "full_name" => @link.repository_full_name },
      "pull_request" => {
        "merged" => false,
        "title" => "Test PR",
        "number" => 1,
        "html_url" => "https://github.com/example/test/pull/1",
        "body" => "This is a test PR",
        "user" => { "login" => "testuser" }
      }
    }
  end

  test "accepts webhook and creates system comment" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, body)}"

    assert_difference "Comment.count", 1 do
      post "/github/webhook",
           params: body,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "HTTP_X_GITHUB_EVENT" => "pull_request",
             "HTTP_X_HUB_SIGNATURE_256" => signature
           }
    end

    assert_response :success

    comment = @creative.effective_origin.comments.last
    assert_nil comment.user, "System comment should have no user"
    assert_includes comment.content, "Pull Request Opened"
    assert_includes comment.content, "Test PR"
    assert_includes comment.content, "webhook-user/example"
  end

  test "does not dispatch for system comments (user nil)" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, body)}"

    dispatched = false

    Collavre::SystemEvents::Dispatcher.stub :dispatch, ->(*_args) { dispatched = true } do
      post "/github/webhook",
           params: body,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "HTTP_X_GITHUB_EVENT" => "pull_request",
             "HTTP_X_HUB_SIGNATURE_256" => signature
           }
    end

    assert_response :success
    refute dispatched, "System comments (user: nil) should not dispatch to orchestration"
  end

  test "does not create comment when repository link not found" do
    payload = @payload.merge("repository" => { "full_name" => "unknown/repo" })
    body = payload.to_json

    fallback_secret = "fallback-test-secret"
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', fallback_secret, body)}"

    Rails.application.stub :credentials, OpenStruct.new(github: { webhook_secret: fallback_secret }) do
      assert_no_difference "Comment.count" do
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
  end

  test "formats push event correctly" do
    push_payload = {
      "ref" => "refs/heads/main",
      "repository" => { "full_name" => @link.repository_full_name },
      "pusher" => { "name" => "testuser" },
      "commits" => [
        { "id" => "abc123def", "message" => "First commit" },
        { "id" => "def456ghi", "message" => "Second commit" }
      ]
    }
    body = push_payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, body)}"

    post "/github/webhook",
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "HTTP_X_GITHUB_EVENT" => "push",
           "HTTP_X_HUB_SIGNATURE_256" => signature
         }

    assert_response :success

    comment = @creative.effective_origin.comments.last
    assert_includes comment.content, "Push to main"
    assert_includes comment.content, "2"
    assert_includes comment.content, "First commit"
  end

  test "rejects webhook when signature does not match secret" do
    body = @payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'wrong-secret', body)}"

    assert_no_difference "Comment.count" do
      post "/github/webhook",
           params: body,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "HTTP_X_GITHUB_EVENT" => "pull_request",
             "HTTP_X_HUB_SIGNATURE_256" => signature
           }
    end

    assert_response :unauthorized
  end

  test "accepts webhook when payload is form encoded" do
    payload_json = @payload.to_json
    form_body = URI.encode_www_form(payload: payload_json)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @link.webhook_secret, form_body)}"

    assert_difference "Comment.count", 1 do
      post "/github/webhook",
           params: { payload: payload_json },
           headers: {
             "CONTENT_TYPE" => "application/x-www-form-urlencoded",
             "HTTP_X_GITHUB_EVENT" => "pull_request",
             "HTTP_X_HUB_SIGNATURE_256" => signature
           }
    end

    assert_response :success
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
