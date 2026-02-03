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
      Collavre::AiAgentJob.stub :perform_later, ->(task) { task.update!(status: "resumed") } do
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
      Collavre::AiAgentJob.stub :perform_later, ->(task) { task.update!(status: "resumed") } do
        Comments::ActionExecutor.new(comment: comment, executor: @user).call
      end
    end

    @task.reload
    assert_equal({ "error" => "Tool failed" }, @task.pending_tool_call["result"])
  end
end
