# frozen_string_literal: true

require "test_helper"

module Collavre
  module Comments
    class ActionExecutorExecuteToolTest < ActiveSupport::TestCase
      setup do
        @user = collavre_users(:one)
        @creative = collavre_creatives(:one)
        @agent = collavre_users(:two) # Use as AI agent

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

        # Create a tool that requires approval
        @mcp_tool = Collavre::McpTool.create!(
          name: "test_tool",
          creative: @creative,
          source_code: "module TestTool; extend ToolMeta; tool_name 'test_tool'; end",
          requires_approval: true,
          approved_at: Time.current
        )
      end

      test "execute_tool action executes tool and resumes task" do
        action_payload = {
          "action" => "execute_tool",
          "tool_name" => "test_tool",
          "arguments" => { "param" => "value" },
          "resume" => {
            "task_id" => @task.id,
            "tool_call_id" => "call_123"
          }
        }

        comment = Collavre::Comment.create!(
          creative: @creative,
          user: @agent,
          content: "Tool approval request",
          approver: @user,
          action: JSON.pretty_generate(action_payload)
        )

        # Mock MetaToolService
        ::Tools::MetaToolService.any_instance.stubs(:call).returns({ result: "success" })

        # Execute the action
        assert_enqueued_with(job: AiAgentJob) do
          ActionExecutor.new(comment: comment, executor: @user).call
        end

        # Verify task was updated
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

        comment = Collavre::Comment.create!(
          creative: @creative,
          user: @agent,
          content: "Tool approval request",
          approver: @user,
          action: JSON.pretty_generate(action_payload)
        )

        error = assert_raises(ActionExecutor::ExecutionError) do
          ActionExecutor.new(comment: comment, executor: @user).call
        end

        assert_match(/Tool name is required/, error.message)
      end

      test "execute_tool handles tool execution errors gracefully" do
        action_payload = {
          "action" => "execute_tool",
          "tool_name" => "test_tool",
          "arguments" => { "param" => "value" },
          "resume" => {
            "task_id" => @task.id,
            "tool_call_id" => "call_123"
          }
        }

        comment = Collavre::Comment.create!(
          creative: @creative,
          user: @agent,
          content: "Tool approval request",
          approver: @user,
          action: JSON.pretty_generate(action_payload)
        )

        # Mock MetaToolService to raise an error
        ::Tools::MetaToolService.any_instance.stubs(:call).raises(StandardError.new("Tool failed"))

        # Execute should not raise, but store error in result
        assert_enqueued_with(job: AiAgentJob) do
          ActionExecutor.new(comment: comment, executor: @user).call
        end

        @task.reload
        assert_equal({ "error" => "Tool failed" }, @task.pending_tool_call["result"])
      end
    end
  end
end
