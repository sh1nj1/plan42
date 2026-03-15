# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../../../test/test_helper"
require "collavre_github"
require "webmock/minitest"
# Allow net connections by default so other engines' tests are not affected.
# collavre_github tests rely on explicit stub_request() calls to intercept GitHub API requests.
WebMock.allow_net_connect!

module CollavreGithubTestHelpers
  def create_user(email: "user@example.com", name: "Test User")
    Collavre.user_class.create!(
      email: email,
      name: name,
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
  end

  def create_creative(user)
    Collavre::Creative.create!(
      description: "GitHub test creative",
      progress: 0.0,
      user: user
    )
  end

  def create_github_account(user, login: "testuser", token: "ghp-test-token-123")
    CollavreGithub::Account.create!(
      user: user,
      github_uid: "#{user.id}00001",
      login: login,
      name: user.name,
      token: token,
      avatar_url: "https://avatars.githubusercontent.com/u/#{user.id}"
    )
  end

  # Stub GitHub organizations API (Octokit adds per_page=100 with auto_paginate)
  def stub_github_organizations(orgs)
    stub_request(:get, %r{https://api\.github\.com/user/orgs})
      .to_return(
        status: 200,
        body: orgs.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub GitHub user repositories API
  def stub_github_user_repos(repos)
    stub_request(:get, %r{https://api\.github\.com/user/repos})
      .to_return(
        status: 200,
        body: repos.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub GitHub org repositories API
  def stub_github_org_repos(org, repos)
    stub_request(:get, %r{https://api\.github\.com/orgs/#{org}/repos})
      .to_return(
        status: 200,
        body: repos.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub GitHub hooks API (for webhook provisioning)
  def stub_github_hooks(repo, hooks: [])
    stub_request(:get, %r{https://api\.github\.com/repos/#{Regexp.escape(repo)}/hooks})
      .to_return(
        status: 200,
        body: hooks.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_github_create_hook(repo)
    stub_request(:post, "https://api.github.com/repos/#{repo}/hooks")
      .to_return(
        status: 201,
        body: { id: rand(10000), active: true }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end

class ActiveSupport::TestCase
  include CollavreGithubTestHelpers
end

class ActionDispatch::SystemTestCase
  include CollavreGithubTestHelpers
end
