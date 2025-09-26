require "test_helper"

class GithubRepositoryLinkTest < ActiveSupport::TestCase
  test "webhook secret is generated automatically" do
    account = GithubAccount.create!(
      user: users(:one),
      github_uid: "999",
      login: "generator",
      name: "Generator",
      token: "token"
    )

    link = GithubRepositoryLink.new(
      creative: creatives(:tshirt),
      github_account: account,
      repository_full_name: "generator/generated"
    )

    assert link.save, -> { link.errors.full_messages.join(", ") }
    assert link.webhook_secret.present?
  end
end
