# frozen_string_literal: true

require_relative "../../test_helper"

class CollavreLinear::CommentLinkTest < ActiveSupport::TestCase
  def setup
    @user = Collavre.user_class.create!(
      email: "cl-test@example.com",
      name: "CL Test User",
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
    @root_creative = Collavre::Creative.create!(
      description: "<p>Root</p>",
      user: @user
    )
    @account = CollavreLinear::Account.create!(
      user: @user,
      linear_uid: "uid-cl",
      access_token: "token-cl"
    )
    @project_link = CollavreLinear::ProjectLink.create!(
      creative: @root_creative,
      account: @account,
      linear_project_id: "proj-cl",
      team_id: "team-cl"
    )
    @issue_creative = Collavre::Creative.create!(
      description: "<p>Issue</p>",
      user: @user
    )
    @issue_link = CollavreLinear::IssueLink.create!(
      creative: @issue_creative,
      project_link: @project_link,
      linear_issue_id: "iss-cl"
    )
    # Create a real comment to use as comment_id reference
    @topic = @root_creative.main_topic
    @comment = Collavre::Comment.create!(
      creative: @root_creative,
      topic: @topic,
      user: @user,
      content: "test comment"
    )
  end

  test "unique index on linear_comment_id" do
    CollavreLinear::CommentLink.create!(
      comment_id: @comment.id,
      linear_comment_id: "lc-1",
      issue_link: @issue_link
    )
    dup = CollavreLinear::CommentLink.new(
      comment_id: @comment.id + 1,
      linear_comment_id: "lc-1",
      issue_link: @issue_link
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "belongs to issue_link" do
    link = CollavreLinear::CommentLink.create!(
      comment_id: @comment.id,
      linear_comment_id: "lc-2",
      issue_link: @issue_link
    )
    assert_equal @issue_link, link.issue_link
  end

  test "stores comment_id and linear_comment_id" do
    link = CollavreLinear::CommentLink.create!(
      comment_id: @comment.id,
      linear_comment_id: "lc-3",
      issue_link: @issue_link
    )
    assert_equal @comment.id, link.comment_id
    assert_equal "lc-3", link.linear_comment_id
  end
end
