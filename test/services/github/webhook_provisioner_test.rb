require "test_helper"

class FakeGithubClient
  attr_reader :hooks_called_with, :create_calls, :update_calls

  def initialize(hooks: [])
    @hooks = hooks
    @create_calls = []
    @update_calls = []
    @hooks_called_with = []
    @error_to_raise = nil
  end

  def repository_hooks(repo_full_name)
    @hooks_called_with << repo_full_name
    @hooks
  end

  def create_repository_webhook(repo_full_name, **kwargs)
    raise @error_to_raise if @error_to_raise

    @create_calls << [ repo_full_name, kwargs ]
  end

  def update_repository_webhook(repo_full_name, hook_id, **kwargs)
    @update_calls << [ repo_full_name, hook_id, kwargs ]
  end

  def simulate_error!(error)
    @error_to_raise = error
  end
end

class Github::WebhookProvisionerTest < ActiveSupport::TestCase
  setup do
    @creative = creatives(:tshirt)
    @user = users(:one)
    @account = GithubAccount.create!(
      user: @user,
      github_uid: "webhook-account",
      login: "webhook-user",
      name: "Webhook User",
      token: "token"
    )
  end

  test "creates webhook when none exists" do
    link = GithubRepositoryLink.create!(
      creative: @creative,
      github_account: @account,
      repository_full_name: "example/repo"
    )

    webhook_url = "https://example.com/github/webhook"
    client = FakeGithubClient.new(hooks: [])

    provisioner = Github::WebhookProvisioner.new(account: @account, webhook_url: webhook_url, client: client)
    provisioner.ensure_for_links([ link ])

    assert_equal [ "example/repo" ], client.hooks_called_with
    assert_equal 1, client.create_calls.size
    repo, options = client.create_calls.first
    assert_equal "example/repo", repo
    assert_equal webhook_url, options[:url]
    assert_equal link.webhook_secret, options[:secret]
    assert_equal [ "pull_request" ], options[:events]
    assert_equal "json", options[:content_type]
  end

  test "updates webhook when existing hook matches url" do
    link = GithubRepositoryLink.create!(
      creative: @creative,
      github_account: @account,
      repository_full_name: "example/repo"
    )

    webhook_url = "https://example.com/github/webhook"
    hook = OpenStruct.new(
      id: 123,
      config: { "url" => webhook_url },
      events: [ "pull_request" ],
      active: true
    )

    client = FakeGithubClient.new(hooks: [ hook ])

    provisioner = Github::WebhookProvisioner.new(account: @account, webhook_url: webhook_url, client: client)
    provisioner.ensure_for_links([ link ])

    assert_equal [], client.create_calls
    assert_equal 1, client.update_calls.size
    repo, hook_id, options = client.update_calls.first
    assert_equal "example/repo", repo
    assert_equal 123, hook_id
    assert_equal webhook_url, options[:url]
    assert_equal link.webhook_secret, options[:secret]
    assert_equal [ "pull_request" ], options[:events]
    assert_equal "json", options[:content_type]
  end

  test "aligns webhook secret with existing link when hook already configured" do
    existing_creative = Creative.create!(
      description: "Existing creative",
      progress: 0.0,
      user: @user
    )

    existing_link = GithubRepositoryLink.create!(
      creative: existing_creative,
      github_account: @account,
      repository_full_name: "example/repo"
    )
    existing_link.update!(webhook_secret: "existing-secret")

    link = GithubRepositoryLink.create!(
      creative: @creative,
      github_account: @account,
      repository_full_name: "example/repo"
    )
    link.update!(webhook_secret: "new-secret")

    webhook_url = "https://example.com/github/webhook"
    hook = OpenStruct.new(
      id: 123,
      config: { "url" => webhook_url },
      events: [ "pull_request" ],
      active: true
    )

    client = FakeGithubClient.new(hooks: [ hook ])

    provisioner = Github::WebhookProvisioner.new(account: @account, webhook_url: webhook_url, client: client)
    provisioner.ensure_for_links([ link ])

    assert_equal [ "example/repo" ], client.hooks_called_with
    assert_equal [], client.create_calls
    assert_equal [], client.update_calls
    assert_equal "existing-secret", link.reload.webhook_secret
  end

  test "ignores errors raised by github client" do
    link = GithubRepositoryLink.create!(
      creative: @creative,
      github_account: @account,
      repository_full_name: "example/repo"
    )

    webhook_url = "https://example.com/github/webhook"
    client = FakeGithubClient.new(hooks: [])
    client.simulate_error!(Octokit::Error.new(response: { status: 500, body: "" }))

    provisioner = Github::WebhookProvisioner.new(account: @account, webhook_url: webhook_url, client: client)

    assert_nothing_raised do
      provisioner.ensure_for_links([ link ])
    end
  end
end
