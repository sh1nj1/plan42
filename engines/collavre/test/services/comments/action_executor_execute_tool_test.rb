# frozen_string_literal: true

require "test_helper"

class Comments::ActionExecutorExecuteToolTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @agent = users(:two) # Use as AI agent

    # Create a task that's pending approval
    @task = Collavre::Task.create!(
      name: "Test task",
      status: "pending_approval",
      trigger_event_name: "comment_created",
      trigger_event_payload: { "creative" => { "id" => @creative.id } },
      agent: @agent,
      pending_tool_call: {
        "tool_name" => "test_tool",
        "tool_call_id" => "call_123",
        "arguments" => { "param" => "value" },
        "requested_at" => Time.current.iso8601
      }
    )

    # Create a tool that requires approval (unique name per test)
    @mcp_tool = Collavre::McpTool.create!(
      name: "test_tool_#{SecureRandom.hex(4)}",
      creative: @creative,
      source_code: "module TestTool; extend ToolMeta; tool_name 'test_tool'; end",
      requires_approval: true,
      approved_at: Time.current
    )
  end

  test "execute_tool action updates task with approval and result" do
    action_payload = {
      "action" => "execute_tool",
      "tool_name" => "test_tool",
      "arguments" => { "param" => "value" },
      "resume" => {
        "task_id" => @task.id,
        "tool_call_id" => "call_123"
      }
    }

    comment = @creative.comments.create!(
      user: @agent,
      content: "Tool approval request",
      approver: @user,
      action: JSON.pretty_generate(action_payload)
    )

    # Mock MetaToolService
    mock_result = { result: "success" }
    mock_service = Object.new
    mock_service.define_singleton_method(:call) { |**_args| mock_result }

    ::Tools::MetaToolService.stub :new, -> { mock_service } do
      # Stub AiAgentJob to prevent actual execution
      Collavre::AiAgentJob.stub :perform_later, ->(task) { task.update!(status: "running") } do
        Comments::ActionExecutor.new(comment: comment, executor: @user).call
      end
    end

    # Verify task was updated with approval info
    @task.reload
    assert_equal true, @task.pending_tool_call["approved"]
    assert_equal({ "result" => "success" }, @task.pending_tool_call["result"])
    assert @task.pending_tool_call["approved_at"].present?

    # Verify comment was marked as executed
    comment.reload
    assert comment.action_executed_at.present?
    assert_equal @user, comment.action_executed_by
  end

  test "execute_tool action fails without tool_name" do
    action_payload = {
      "action" => "execute_tool",
      "arguments" => { "param" => "value" }
    }

    comment = @creative.comments.create!(
      user: @agent,
      content: "Tool approval request",
      approver: @user,
      action: JSON.pretty_generate(action_payload)
    )

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      Comments::ActionExecutor.new(comment: comment, executor: @user).call
    end

    assert_match(/Tool name is required/, error.message)
  end

  test "execute_tool stores error in result when tool execution fails" do
    action_payload = {
      "action" => "execute_tool",
      "tool_name" => "test_tool",
      "arguments" => { "param" => "value" },
      "resume" => {
        "task_id" => @task.id,
        "tool_call_id" => "call_123"
      }
    }

    comment = @creative.comments.create!(
      user: @agent,
      content: "Tool approval request",
      approver: @user,
      action: JSON.pretty_generate(action_payload)
    )

    # Mock MetaToolService to raise an error
    error_service = Object.new
    error_service.define_singleton_method(:call) { |**_args| raise StandardError, "Tool failed" }

    ::Tools::MetaToolService.stub :new, -> { error_service } do
      Collavre::AiAgentJob.stub :perform_later, ->(task) { task.update!(status: "running") } do
        Comments::ActionExecutor.new(comment: comment, executor: @user).call
      end
    end

    @task.reload
    assert_equal({ "error" => "Tool failed" }, @task.pending_tool_call["result"])
  end

  # Stop is reachable while a turn waits on approval, and stopping it leaves the
  # approval comment on screen. Approving afterwards used to run the tool anyway
  # — the resumed job then exited on the cancelled task, so the side effect
  # happened with nothing left to consume it.
  test "a stopped turn does not run the tool it was waiting on" do
    @task.update!(status: "cancelled")

    invoked = false
    service = Object.new
    service.define_singleton_method(:call) { |**_args| invoked = true }

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      ::Tools::MetaToolService.stub :new, -> { service } do
        Comments::ActionExecutor.new(comment: approval_comment, executor: @user).call
      end
    end

    refute invoked, "the tool ran for a cancelled turn"
    assert_match(/stopped/i, error.message)
  end

  # The comment stays un-executed so the row does not read as an action that
  # already ran, and the cancelled turn keeps its record of what was refused.
  test "refusing a stopped turn leaves the comment and task untouched" do
    @task.update!(status: "cancelled")
    comment = approval_comment

    assert_raises(Comments::ActionExecutor::ExecutionError) do
      ::Tools::MetaToolService.stub :new, -> { Object.new } do
        Comments::ActionExecutor.new(comment: comment, executor: @user).call
      end
    end

    assert_nil comment.reload.action_executed_at
    refute @task.reload.pending_tool_call.key?("approved")
  end

  # A task can be re-paused on a newer tool call, which leaves the earlier
  # approval comment behind. Approving the stale one must not run its tool.
  test "an approval superseded by a newer tool call is refused" do
    comment = approval_comment
    @task.update!(pending_tool_call: @task.pending_tool_call.merge("tool_call_id" => "call_456"))

    invoked = false
    service = Object.new
    service.define_singleton_method(:call) { |**_args| invoked = true }

    assert_raises(Comments::ActionExecutor::ExecutionError) do
      ::Tools::MetaToolService.stub :new, -> { service } do
        Comments::ActionExecutor.new(comment: comment, executor: @user).call
      end
    end

    refute invoked, "the tool ran for a superseded approval"
  end

  private

  def approval_comment
    @creative.comments.create!(
      user: @agent,
      content: "Tool approval request",
      approver: @user,
      action: JSON.pretty_generate(
        "action" => "execute_tool",
        "tool_name" => "test_tool",
        "arguments" => { "param" => "value" },
        "resume" => { "task_id" => @task.id, "tool_call_id" => "call_123" }
      )
    )
  end
end
