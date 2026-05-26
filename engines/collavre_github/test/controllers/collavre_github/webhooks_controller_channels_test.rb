require_relative "../../test_helper"

module CollavreGithub
  class WebhooksControllerChannelsTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @account = CollavreGithub::Account.create!(
        user: @user,
        github_uid: "12345",
        login: "testuser",
        name: "Test",
        token: "test-token"
      )
      @link = CollavreGithub::RepositoryLink.create!(
        creative: @creative,
        github_account: @account,
        repository_full_name: "owner/repo"
      )
      @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "T")
      @channel = GithubPrChannel.create!(
        topic: @topic,
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 99 }
      )
    end

    test "issue_comment.created on monitored PR injects a comment into the topic" do
      payload = {
        action: "created",
        comment: {
          id: 1,
          body: "fix typo",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 99, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json

      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
        post "/github/webhook",
          params: payload,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "issue_comment",
            "X-Hub-Signature-256" => sig
          }
      end
      assert_response :ok
    end
  end
end
