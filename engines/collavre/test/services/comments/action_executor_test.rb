require "test_helper"
require "json"

class Comments::ActionExecutorTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @approver = users(:two)
    @creative = creatives(:tshirt)
  end

  test "marks execution metadata and preserves action history" do
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

    Comments::ActionExecutor.new(comment: comment, executor: @user).call

    comment.reload
    assert_equal action_payload, JSON.parse(comment.action)
    assert_equal @user.id, comment.approver.id
    assert_not_nil comment.action_executed_at
    assert_equal @user.id, comment.action_executed_by.id
    assert_in_delta 0.5, comment.creative.reload.progress
  end

  test "resets execution metadata when action fails" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 2.0 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end
    assert_match "less than or equal to 1.0", error.message

    comment.reload
    assert_nil comment.action_executed_at
    assert_nil comment.action_executed_by
  end

  test "creates a child creative using the approval action" do
    action_payload = {
      "action" => "create_creative",
      "attributes" => {
        "description" => "New idea",
        "progress" => 0.25
      }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    assert_difference -> { @creative.reload.children.count }, 1 do
      Comments::ActionExecutor.new(comment: comment, executor: @user).call
    end

    child = @creative.reload.children.order(:created_at).last
    assert_equal "New idea", ActionController::Base.helpers.strip_tags(child.description).strip
    assert_in_delta 0.25, child.progress
    assert_equal @creative.user.id, child.user.id
  end

  test "supports multiple actions within a single payload" do
    child = Creative.create!(user: @user, parent: @creative, description: "Child", progress: 0.2)

    action_payload = {
      "actions" => [
        {
          "action" => "update_creative",
          "creative_id" => child.id,
          "attributes" => { "progress" => 1.0 }
        },
        {
          "action" => "create_creative",
          "parent_id" => @creative.id,
          "attributes" => { "description" => "Follow up" }
        }
      ]
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @approver
    )

    Comments::ActionExecutor.new(comment: comment, executor: @approver).call

    child.reload
    assert_in_delta 1.0, child.progress
    new_child = @creative.children.order(:created_at).last
    assert_equal "Follow up", ActionController::Base.helpers.strip_tags(new_child.description).strip
    assert_equal @creative, new_child.parent
  end

  test "rolls back all actions when one fails" do
    child = Creative.create!(user: @user, parent: @creative, description: "Child", progress: 0.2)

    action_payload = {
      "actions" => [
        {
          "action" => "update_creative",
          "creative_id" => child.id,
          "attributes" => { "progress" => 0.9 }
        },
        {
          "action" => "update_creative",
          "creative_id" => child.id,
          "attributes" => { "progress" => 2.0 }
        }
      ]
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @approver
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @approver)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end
    assert_match "less than or equal to 1.0", error.message

    child.reload
    assert_in_delta 0.2, child.progress
  end

  test "raises when action targets creative outside the comment tree" do
    external = Creative.create!(user: @user, description: "External")

    action_payload = {
      "action" => "update_creative",
      "creative_id" => external.id,
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end

    assert_equal I18n.t("comments.approve_invalid_creative"), error.message
  end

  test "rejects actions outside the linked creative subtree" do
    root = Creative.create!(user: @user, description: "Root")
    linked = Creative.create!(user: @user, parent: root, description: "Linked")
    sibling = Creative.create!(user: @user, parent: root, description: "Sibling")

    action_payload = {
      "action" => "update_creative",
      "creative_id" => sibling.id,
      "attributes" => { "progress" => 0.5 }
    }

    comment = linked.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end

    assert_equal I18n.t("comments.approve_invalid_creative"), error.message
  end

  test "raises when executor no longer matches approver" do
    approver = users(:two)

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate("action" => "update_creative", "attributes" => { "progress" => 0.5 }),
      approver: @user
    )

    stale_comment = Comment.find(comment.id)
    comment.update!(approver: approver)

    executor = Comments::ActionExecutor.new(comment: stale_comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end

    assert_equal I18n.t("comments.approve_not_allowed"), error.message
    comment.reload
    assert_nil comment.action_executed_at
    assert_nil comment.action_executed_by
  end
end
