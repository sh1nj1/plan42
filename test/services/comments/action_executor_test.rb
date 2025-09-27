require "test_helper"

class Comments::ActionExecutorTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
  end

  test "marks execution metadata and preserves action history" do
    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: "creative.update!(progress: 0.5)",
      approver: @user
    )

    Comments::ActionExecutor.new(comment: comment).call

    comment.reload
    assert_equal "creative.update!(progress: 0.5)", comment.action
    assert_equal @user, comment.approver
    assert_not_nil comment.action_executed_at
    assert_equal @user, comment.action_executed_by
    assert_in_delta 0.5, comment.creative.reload.progress
  end

  test "resets execution metadata when action fails" do
    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: "raise 'boom'",
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end
    assert_match "boom", error.message

    comment.reload
    assert_nil comment.action_executed_at
    assert_nil comment.action_executed_by
  end
end
