# frozen_string_literal: true

require_relative "../../test_helper"

class CollavreLinear::IssueLinkTest < ActiveSupport::TestCase
  def setup
    @user = Collavre.user_class.create!(
      email: "il-test@example.com",
      name: "IL Test User",
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
    @creative = Collavre::Creative.create!(
      description: "<p>Root creative</p>",
      user: @user
    )
    @account = CollavreLinear::Account.create!(
      user: @user,
      linear_uid: "uid-il",
      access_token: "token-il"
    )
    @project_link = CollavreLinear::ProjectLink.create!(
      creative: @creative,
      account: @account,
      linear_project_id: "proj-for-issue",
      team_id: "team-for-issue"
    )
    @issue_creative = Collavre::Creative.create!(
      description: "<p>Issue creative</p>",
      user: @user
    )
  end

  test "requires a project_link" do
    link = CollavreLinear::IssueLink.new(
      creative: @issue_creative,
      linear_issue_id: "iss-1"
      # no project_link
    )
    refute link.valid?
    assert link.errors[:project_link].any?
  end

  test "sync_state defaults to synced" do
    link = CollavreLinear::IssueLink.create!(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-2"
    )
    assert_equal "synced", link.sync_state
  end

  test "sync_state enum rejects unknown values" do
    link = CollavreLinear::IssueLink.new(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-3"
    )
    assert_raises(ArgumentError) { link.sync_state = "bogus" }
  end

  test "local_version defaults to 0" do
    link = CollavreLinear::IssueLink.create!(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-4"
    )
    assert_equal 0, link.local_version
  end

  test "unique index on creative_id" do
    CollavreLinear::IssueLink.create!(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-5"
    )
    dup = CollavreLinear::IssueLink.new(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-5b"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "unique index on linear_issue_id" do
    c2 = Collavre::Creative.create!(description: "<p>c2</p>", user: @user)
    CollavreLinear::IssueLink.create!(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "dup-iss"
    )
    dup = CollavreLinear::IssueLink.new(
      creative: c2,
      project_link: @project_link,
      linear_issue_id: "dup-iss"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "parent_issue_id is optional" do
    link = CollavreLinear::IssueLink.create!(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-6",
      parent_issue_id: nil
    )
    assert_nil link.parent_issue_id
  end

  test "belongs to project_link and creative" do
    link = CollavreLinear::IssueLink.create!(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-7"
    )
    assert_equal @project_link, link.project_link
    assert_equal @issue_creative, link.creative
  end
end
