require "test_helper"
require "minitest/mock"

class GithubIntegrationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @agent = User.create!(
      email: "github-pr-analyzer@system.local",
      name: "GitHub PR Analyzer",
      password: "password",
      system_prompt: "{{ creative.github_gemini_prompt_template }}",
      routing_expression: "event_name == 'github.pull_request'",
      llm_vendor: "google",
      llm_model: "gemini-1.5-flash-latest",
      searchable: true
    )

    @user = User.create!(email: "testuser@example.com", name: "Test User", password: "password")
    @creative = Creative.create!(description: "Test Creative", user: @user)

    @github_account = GithubAccount.create!(
      user: @user,
      github_uid: "12345",
      login: "testuser",
      token: "gh_token"
    )

    @link = GithubRepositoryLink.create!(
      creative: @creative,
      github_account: @github_account,
      repository_full_name: "testuser/testrepo",
      webhook_secret: "secret"
    )
  end

  test "webhook triggers agent and creates comment" do
    payload = {
      action: "opened",
      number: 1,
      pull_request: {
        number: 1,
        title: "Test PR",
        body: "Test Body",
        html_url: "http://github.com/testuser/testrepo/pull/1",
        user: { login: "pr-author" }
      },
      repository: {
        full_name: "testuser/testrepo",
        owner: { login: "testuser" }
      }
    }

    # Mock Github Client
    mock_gh_client = Minitest::Mock.new
    mock_gh_client.expect(:pull_request_commit_messages, [ "Initial Commit" ], [ "testuser/testrepo", 1 ])
    mock_gh_client.expect(:pull_request_diff, "diff --git a/foo.rb b/foo.rb\n+ foo", [ "testuser/testrepo", 1 ])

    # Mock AI Client
    mock_ai_client = Minitest::Mock.new
    # Expect chat call. The first arg is messages.
    # We just return a lambda to yield the response
    response_json = {
      completed: [ { creative_id: @creative.id, progress: 1.0, note: "Done" } ],
      additional: []
    }.to_json

    # We mock valid response from AI
    mock_ai_client.expect(:chat, nil) do |messages, options, &block|
      block.call(response_json)
      true
    end

    Github::Client.stub :new, mock_gh_client do
      AiClient.stub :new, mock_ai_client do
        perform_enqueued_jobs do
          post "/github/webhook",
               params: payload.to_json,
               headers: {
                 "X-GitHub-Event" => "pull_request",
                 "Content-Type" => "application/json",
                 "X-Hub-Signature-256" => "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", "secret", payload.to_json)
               }
        end
      end
    end

    assert_response :ok

    # Verify Comment Created
    last_comment = @creative.comments.last
    assert_not_nil last_comment
    assert_includes last_comment.content, "GitHub PR Analysis"
    assert_includes last_comment.content, "Creative ##{@creative.id}: Done"

    # Verify Actions
    assert last_comment.action.present?
    actions = JSON.parse(last_comment.action)["actions"]
    assert_equal 1, actions.length
    assert_equal "update_creative", actions[0]["action"]

    assert_mock mock_gh_client
    assert_mock mock_ai_client
  end
end
