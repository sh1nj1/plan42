require_relative "../../test_helper"

module CollavreGithub
  class WebhooksControllerAutoAttachTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @account = CollavreGithub::Account.create!(
        user: @user, github_uid: "12345", login: "testuser",
        name: "Test", token: "test-token"
      )
      @link = CollavreGithub::RepositoryLink.create!(
        creative: @creative, github_account: @account,
        repository_full_name: "owner/repo"
      )
      @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "T")
    end

    test "pull_request.opened with topic link in body creates a channel" do
      payload = {
        action: "opened",
        pull_request: {
          number: 555,
          html_url: "https://github.com/#{@link.repository_full_name}/pull/555",
          body: "Linked topic: /creatives/#{@creative.id}/topics/#{@topic.id}"
        },
        repository: { full_name: @link.repository_full_name }
      }.to_json

      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { GithubPrChannel.count }, 1 do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request",
            "X-Hub-Signature-256" => sig
          }
      end
      channel = GithubPrChannel.last
      assert_equal @topic.id, channel.topic_id
      assert_equal 555, channel.pr_number
      assert_equal @link.repository_full_name, channel.repo_full_name
    end

    test "pull_request.opened without topic link does not create a channel" do
      payload = {
        action: "opened",
        pull_request: { number: 556, body: "no topic link here" },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_no_difference -> { GithubPrChannel.count } do
        post "/github/webhook", params: payload,
          headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request", "X-Hub-Signature-256" => sig }
      end
    end
  end
end
