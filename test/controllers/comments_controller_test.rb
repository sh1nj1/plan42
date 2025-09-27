require "test_helper"
require "json"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "convert markdown comment to sub creatives" do
    comment = @creative.comments.create!(content: "- First\n- Second", user: @user)
    assert_difference("Creative.count", 2) do
      assert_no_difference("Comment.count") do
        post convert_creative_comment_path(@creative, comment)
      end
    end
    assert_response :no_content
    @creative.reload
    titles = @creative.children.order(:id).map { |c| c.description.to_plain_text.strip }
    assert_equal [ "First", "Second" ], titles

    system_comment = @creative.comments.order(:id).last
    assert_nil system_comment.user
    first_child = @creative.children.order(:id).first
    expected_title = first_child.description.to_plain_text.strip
    expected_message = I18n.t(
      "comments.convert_system_message",
      title: expected_title,
      url: creative_path(first_child)
    )
    assert_equal expected_message, system_comment.content
  end

  test "approver can execute comment action" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Run action",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    post approve_creative_comment_path(@creative, comment)

    assert_response :success
    comment.reload
    assert_equal action_payload, JSON.parse(comment.action)
    assert_equal @user, comment.approver
    assert_not_nil comment.action_executed_at
    assert_equal @user, comment.action_executed_by
    assert_in_delta 0.9, comment.creative.reload.progress
  end

  test "cannot execute comment action more than once" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Run action",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    post approve_creative_comment_path(@creative, comment)
    assert_response :success

    post approve_creative_comment_path(@creative, comment)

    assert_response :unprocessable_entity
    response_body = JSON.parse(@response.body)
    assert_equal I18n.t("comments.approve_already_executed"), response_body["error"]
  end

  test "non approver cannot execute comment action" do
    approver = users(:two)
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: approver
    )

    assert_no_changes -> { comment.reload.action } do
      post approve_creative_comment_path(@creative, comment)
      assert_response :forbidden
    end
  end

  test "approver can execute private comment action" do
    approver = users(:two)
    approver.update!(email_verified_at: Time.current)

    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      private: true,
      action: JSON.generate(action_payload),
      approver: approver
    )

    delete session_path
    post session_path, params: { email: approver.email, password: "password" }

    post approve_creative_comment_path(@creative, comment)

    assert_response :success
    assert_not_nil comment.reload.action_executed_at
  end

  test "approver sees private comments in index" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)

    comment = @creative.comments.create!(
      content: "Private for approver",
      user: other_user,
      private: true,
      approver: @user
    )

    get creative_comments_path(@creative), params: { page: 1, per_page: 10 }

    assert_response :success
    assert_includes @response.body, comment.content
  end

  test "commenters cannot set approval attributes when creating" do
    assert_difference("Comment.count", 1) do
      post creative_comments_path(@creative), params: {
        comment: {
          content: "Needs approval",
          private: false,
          action: "User.count",
          approver_id: @user.id
        }
      }
    end

    comment = @creative.comments.order(:id).last
    assert_nil comment.action
    assert_nil comment.approver_id
  end

  test "commenters cannot set approval attributes when updating" do
    comment = @creative.comments.create!(content: "Needs approval", user: @user)

    patch creative_comment_path(@creative, comment), params: {
      comment: {
        content: "Updated",
        action: "User.count",
        approver_id: @user.id
      }
    }

    comment.reload
    assert_equal "Updated", comment.content
    assert_nil comment.action
    assert_nil comment.approver_id
  end
end
