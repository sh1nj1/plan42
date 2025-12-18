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
    titles = @creative.children.order(:id).map { |c| ActionController::Base.helpers.strip_tags(c.description).strip }
    assert_equal [ "First", "Second" ], titles

    system_comment = @creative.comments.order(:id).last
    assert_nil system_comment.user
    first_child = @creative.children.order(:id).first
    expected_title = ActionController::Base.helpers.strip_tags(first_child.description).strip
    expected_message = I18n.t(
      "comments.convert_system_message",
      title: expected_title,
      url: creative_path(first_child)
    )
    assert_equal expected_message, system_comment.content
  end

  test "creative admin can convert another user's comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)

    shared_creative = Creative.create!(user: other_user, description: "Shared Creative", progress: 0.0)
    CreativeShare.create!(creative: shared_creative, user: @user, permission: :admin, shared_by: other_user)

    comment = shared_creative.comments.create!(content: "- Shared task", user: other_user)

    assert_difference("Creative.count", 1) do
      assert_no_difference("Comment.count") do
        post convert_creative_comment_path(shared_creative, comment)
      end
    end

    assert_response :no_content
    shared_creative.reload
    converted_child = shared_creative.children.order(:id).last
    assert_equal "Shared task", ActionController::Base.helpers.strip_tags(converted_child.description).strip
    assert_equal other_user, converted_child.user
  end

  test "converted creatives inherit parent creative user" do
    commenter = users(:two)
    commenter.update!(email_verified_at: Time.current)

    comment = @creative.comments.create!(content: "- Cross user task", user: commenter)

    assert_difference("Creative.count", 1) do
      assert_no_difference("Comment.count") do
        post convert_creative_comment_path(@creative, comment)
      end
    end

    assert_response :no_content
    child = @creative.children.order(:id).last
    assert_equal @creative.user, child.user
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
    assert_includes @response.body, I18n.t("comments.approved_label")
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

  test "user can attach images to a comment" do
    assert_difference -> { ActiveStorage::Attachment.where(record_type: "Comment").count }, 1 do
      post creative_comments_path(@creative), params: {
        comment: {
          content: "",
          images: [ fixture_file_upload(file_fixture("small.png"), "image/png") ]
        }
      }

      assert_response :created
    end

    comment = @creative.comments.order(:id).last
    assert comment.images.attached?
  end

  test "rejects non-image attachments on comments" do
    assert_no_difference [ "Comment.count", "ActiveStorage::Attachment.count", "ActiveStorage::Blob.count" ] do
      post creative_comments_path(@creative), params: {
        comment: {
          content: "",
          images: [ fixture_file_upload(file_fixture("invalid.txt"), "text/plain") ]
        }
      }

      assert_response :unprocessable_entity
    end

    errors = JSON.parse(@response.body)["errors"]
    assert_includes errors, "Images must be an image"
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

  test "user can move comments to another creative" do
    target = creatives(:childless_creative)
    comment = @creative.comments.create!(content: "Move me", user: @user)

    assert_changes -> { comment.reload.creative }, from: @creative, to: target.effective_origin do
      post move_creative_comments_path(@creative), params: {
        comment_ids: [ comment.id ],
        target_creative_id: target.id
      }, as: :json
      assert_response :success
    end

    response_body = JSON.parse(@response.body)
    assert_equal true, response_body["success"]
  end

  test "cannot move comments without permission on target" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    target = Creative.create!(user: other_user, description: "Restricted", progress: 0.0)
    comment = @creative.comments.create!(content: "Move me", user: @user)

    assert_no_changes -> { comment.reload.creative } do
      post move_creative_comments_path(@creative), params: {
        comment_ids: [ comment.id ],
        target_creative_id: target.id
      }, as: :json
      assert_response :forbidden
    end

    response_body = JSON.parse(@response.body)
    assert_equal I18n.t("comments.move_not_allowed"), response_body["error"]
  end

  test "approver can update comment action" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    updated_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.75 }
    }

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(updated_payload) }
    }

    assert_response :success
    comment.reload
    assert_equal updated_payload, JSON.parse(comment.action)
  end

  test "approver cannot update action with invalid payload" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: "{ invalid json" }
    }

    assert_response :unprocessable_entity
    body = JSON.parse(@response.body)
    assert_equal I18n.t("comments.approve_invalid_format"), body["error"]
    assert_equal action_payload, JSON.parse(comment.reload.action)
  end

  test "non approver cannot update comment action" do
    approver = users(:two)
    approver.update!(email_verified_at: Time.current)

    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: approver,
      action: JSON.generate(action_payload),
      approver: approver
    )

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(action_payload.merge("attributes" => { "progress" => 0.7 })) }
    }

    assert_response :forbidden
  end

  test "cannot update action after execution" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user,
      action_executed_at: Time.current,
      action_executed_by: @user
    )

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(action_payload.merge("attributes" => { "progress" => 0.8 })) }
    }

    assert_response :unprocessable_entity
    body = JSON.parse(@response.body)
    assert_equal I18n.t("comments.approve_already_executed"), body["error"]
  end

  test "comment owner can delete their own comment" do
    comment = @creative.comments.create!(content: "My comment", user: @user)

    assert_difference("Comment.count", -1) do
      delete creative_comment_path(@creative, comment)
    end

    assert_response :no_content
  end

  test "creative owner can delete any comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    comment = @creative.comments.create!(content: "Other user comment", user: other_user)

    assert_difference("Comment.count", -1) do
      assert_difference("InboxItem.count", 1) do
        delete creative_comment_path(@creative, comment)
      end
    end

    assert_response :no_content

    # Verify inbox notification was created
    inbox_item = InboxItem.order(:id).last
    assert_equal other_user, inbox_item.owner
    assert_equal "inbox.comment_deleted_by_admin", inbox_item.message_key
    assert_equal @user.name, inbox_item.message_params["admin_name"]
    assert_equal "Other user comment", inbox_item.message_params["comment_content"]
  end

  test "admin user can delete any comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)

    # Create a creative owned by other_user
    other_creative = Creative.create!(user: other_user, description: "Other creative", progress: 0.0)

    # Share with admin permission to @user
    CreativeShare.create!(creative: other_creative, user: @user, permission: :admin, shared_by: other_user)

    # Create comment by other_user
    comment = other_creative.comments.create!(content: "Comment to delete", user: other_user)

    assert_difference("Comment.count", -1) do
      assert_difference("InboxItem.count", 1) do
        delete creative_comment_path(other_creative, comment)
      end
    end

    assert_response :no_content
  end

  test "non-owner non-admin cannot delete comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    comment = @creative.comments.create!(content: "Protected comment", user: other_user)

    # Login as a different user
    third_user = User.create!(
      name: "Third User",
      email: "third@example.com",
      password: "password",
      email_verified_at: Time.current
    )
    delete session_path
    post session_path, params: { email: third_user.email, password: "password" }

    assert_no_difference("Comment.count") do
      delete creative_comment_path(@creative, comment)
    end

    assert_response :forbidden
  end

  test "deleting AI user comment does not create inbox notification" do
    ai_user = User.create!(
      name: "AI Bot",
      email: "aibot@ai.local",
      password: SecureRandom.hex(32),
      llm_vendor: "google",
      llm_model: "gemini-2.5-flash",
      system_prompt: "I am a bot",
      email_verified_at: Time.current
    )

    comment = @creative.comments.create!(content: "AI response", user: ai_user)

    assert_difference("Comment.count", -1) do
      assert_no_difference("InboxItem.count") do
        delete creative_comment_path(@creative, comment)
      end
    end

    assert_response :no_content
  end

  test "comment owner deleting own comment does not create inbox notification" do
    comment = @creative.comments.create!(content: "My own comment", user: @user)

    assert_difference("Comment.count", -1) do
      assert_no_difference("InboxItem.count") do
        delete creative_comment_path(@creative, comment)
      end
    end

    assert_response :no_content
  end
end
