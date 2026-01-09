require "test_helper"
require "json"

class Comments::ActionExecutorSystemSettingTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @admin = users(:two)
    @creative = creatives(:tshirt)

    # Enable the setting
    SystemSetting.create!(key: "mcp_tool_approval_required", value: "true")

    @admin.update!(system_admin: true, email: "admin@example.com")
    @user.update!(system_admin: false)
  end

  teardown do
     SystemSetting.where(key: "mcp_tool_approval_required").destroy_all
  end

  test "mcp tool approval action raises error for non-admin when setting is enabled" do
     action_payload = {
      "action" => "approve_tool",
      "tool_name" => "test_tool"
     }

     comment = @creative.comments.create!(
       content: "Approve tool",
       user: @user,
       action: JSON.generate(action_payload),
       approver: nil
     )

     executor = Comments::ActionExecutor.new(comment: comment, executor: @user)

     assert_raises(Comments::ActionExecutor::ExecutionError) do
       executor.call
     end
  end

  test "mcp tool approval action succeeds for admin when setting is enabled" do
     action_payload = {
      "action" => "approve_tool",
      "tool_name" => "test_tool"
     }

     McpTool.create!(creative: @creative, name: "test_tool", source_code: "tool_name 'test_tool'")

     comment = @creative.comments.create!(
       content: "Approve tool",
       user: @user,
       action: JSON.generate(action_payload),
       approver: @user
     )

     executor = Comments::ActionExecutor.new(comment: comment, executor: @admin)

     McpService.stub :register_tool_from_source, true do
       executor.call
     end

     comment.reload
     assert_not_nil comment.action_executed_at
     assert_equal @admin, comment.action_executed_by
     assert_equal @admin, comment.approver # Should be updated to executor because admin overrode it
  end

  test "normal approval still works when setting is enabled but action is not mcp approval" do
     action_payload = {
       "action" => "update_creative",
       "attributes" => { "progress" => 0.5 }
     }

     comment = @creative.comments.create!(
       content: "Update creative",
       user: @user,
       action: JSON.generate(action_payload),
       approver: @user
     )

     # User can execute because it matches approver
     Comments::ActionExecutor.new(comment: comment, executor: @user).call

     comment.reload
     assert_not_nil comment.action_executed_at
  end

  test "system admin CANNOT approve normal action when setting is enabled if not approver" do
     action_payload = {
       "action" => "update_creative",
       "attributes" => { "progress" => 0.6 }
     }

     comment = @creative.comments.create!(
       content: "Update creative",
       user: @user,
       action: JSON.generate(action_payload),
       approver: @user
     )

     # Admin is NOT the approver. Even if setting is ON and user IS admin,
     # normal actions should NOT allow override (requested behavior change).
     assert_raises(Comments::ActionExecutor::ExecutionError) do
       Comments::ActionExecutor.new(comment: comment, executor: @admin).call
     end

     comment.reload
     assert_nil comment.action_executed_at
  end


  test "nested approve_tool in actions array requires system admin even if approver matches" do
     # Create the tool so the action is valid
     McpTool.create!(creative: @creative, name: "test_tool", source_code: "tool_name 'test_tool'")

     # Payload with approve_tool hidden in actions array
     action_payload = {
       "actions" => [
         { "action" => "approve_tool", "tool_name" => "test_tool" }
       ]
     }

     comment = @creative.comments.create!(
       content: "Sneaky approve tool",
       user: @user,
       action: JSON.generate(action_payload),
       approver: @user # User is the assigned approver, but non-admin
     )

     # Should fail because system setting is ON, so strict admin check should apply
     # logic should detect approve_tool inside actions
     McpService.stub :register_tool_from_source, true do
       assert_raises(Comments::ActionExecutor::ExecutionError) do
         Comments::ActionExecutor.new(comment: comment, executor: @user).call
       end
     end
  end

  test "alias type: approve_tool in nested payload also requires system admin" do
     # Payload using "type" instead of "action"
     action_payload = {
       "actions" => [
         { "type" => "approve_tool", "tool_name" => "test_tool" }
       ]
     }

     comment = @creative.comments.create!(
       content: "Sneaky alias tool",
       user: @user,
       action: JSON.generate(action_payload),
       approver: @user
     )

     McpService.stub :register_tool_from_source, true do
       assert_raises(Comments::ActionExecutor::ExecutionError) do
         Comments::ActionExecutor.new(comment: comment, executor: @user).call
       end
     end
  end
end
