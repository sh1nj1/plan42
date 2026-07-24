require_relative "../test_helper"

module CollavreGithub
  class PrChannelEndToEndTest < ActionDispatch::IntegrationTest
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
        config: { "repo_full_name" => @link.repository_full_name, "pr_number" => 321 }
      )
    end

    test "webhook → channel → comment → orchestration dispatch" do
      payload = {
        action: "created",
        comment: {
          id: 9,
          body: "please rename",
          user: { login: "alice", type: "User", id: 1 }
        },
        issue: { number: 321, pull_request: {} },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)

      dispatched_events = []
      Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(event, _ctx) { dispatched_events << event; [] }) do
        assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
          post "/github/webhook",
            params: payload,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "issue_comment",
              "X-Hub-Signature-256" => sig
            }
        end
      end

      assert_response :ok
      assert_includes dispatched_events, "comment_created",
        "Channel-injected comment must trigger orchestration"
      assert_equal "PR #321", @channel.reload.latest_label
    end

    test "redelivered pull_request.closed webhook only injects one closing comment" do
      payload = {
        action: "closed",
        pull_request: { number: 321, merged: true, html_url: "https://github.com/owner/repo/pull/321" },
        repository: { full_name: @link.repository_full_name }
      }.to_json
      sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @link.webhook_secret, payload)
      headers = {
        "Content-Type" => "application/json",
        "X-GitHub-Event" => "pull_request",
        "X-Hub-Signature-256" => sig
      }

      Collavre::SystemEvents::Dispatcher.stub(:dispatch, ->(_event, _ctx) { [] }) do
        # GitHub redelivers a webhook when the receiver 5xx's. The second
        # delivery must short-circuit (row lock + state re-check) instead of
        # injecting another "PR #321 was merged" comment into the topic.
        assert_difference -> { Collavre::Comment.where(topic_id: @topic.id).count }, 1 do
          2.times { post "/github/webhook", params: payload, headers: headers }
        end
      end

      assert_predicate @channel.reload, :detached?
      assert_equal "merged", @channel.pr_state
    end
  end
end
