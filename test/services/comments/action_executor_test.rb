require "test_helper"
require "json"

class Comments::ActionExecutorTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
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
    assert_equal @user, comment.approver
    assert_not_nil comment.action_executed_at
    assert_equal @user, comment.action_executed_by
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
    assert_equal "New idea", child.description.to_plain_text.strip
    assert_in_delta 0.25, child.progress
    assert_equal @creative.user, child.user
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
