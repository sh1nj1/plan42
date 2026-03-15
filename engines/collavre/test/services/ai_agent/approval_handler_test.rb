# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class ApprovalHandlerTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:two)
        @creative = creatives(:tshirt)
        @creative.update!(user: @user)

        @task = Collavre::Task.create!(
          name: "Test task",
          status: "running",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "comment" => { "user_id" => @user.id }
          },
          agent: @agent
        )

        @error = ApprovalPendingError.new(
          "Tool requires approval",
          tool_call: OpenStruct.new(
            name: "update_creative",
            id: "call_abc123",
            arguments: { "creative_id" => 42, "description" => "New description" }
          ),
          task: @task
        )

        @context = @task.trigger_event_payload
      end

      test "approval comment includes summary when provided" do
        handler = ApprovalHandler.new(
          task: @task,
          agent: @agent,
          context: @context,
          creative: @creative
        )

        summary = "Updates the description of creative #42 to 'New description'."

        assert_difference "Comment.count", 1 do
          handler.handle(@error, summary: summary)
        end

        comment = Comment.last
        assert_includes comment.content, I18n.t("collavre.ai_agent.approval.summary_header")
        assert_includes comment.content, "Updates the description of creative #42"
      end

      test "approval comment works without summary" do
        handler = ApprovalHandler.new(
          task: @task,
          agent: @agent,
          context: @context,
          creative: @creative
        )

        assert_difference "Comment.count", 1 do
          handler.handle(@error, summary: nil)
        end

        comment = Comment.last
        refute_includes comment.content, I18n.t("collavre.ai_agent.approval.summary_header")
        assert_includes comment.content, "update_creative"
      end

      test "approval comment works when summary is not passed" do
        handler = ApprovalHandler.new(
          task: @task,
          agent: @agent,
          context: @context,
          creative: @creative
        )

        assert_difference "Comment.count", 1 do
          handler.handle(@error)
        end

        comment = Comment.last
        refute_includes comment.content, I18n.t("collavre.ai_agent.approval.summary_header")
        assert_includes comment.content, "update_creative"
      end

      test "approval comment has correct action payload" do
        handler = ApprovalHandler.new(
          task: @task,
          agent: @agent,
          context: @context,
          creative: @creative
        )

        handler.handle(@error)

        comment = Comment.last
        action = JSON.parse(comment.action)
        assert_equal "execute_tool", action["action"]
        assert_equal "update_creative", action["tool_name"]
        assert_equal @task.id, action["resume"]["task_id"]
        assert_equal "call_abc123", action["resume"]["tool_call_id"]
      end

      test "task is updated to pending_approval status" do
        handler = ApprovalHandler.new(
          task: @task,
          agent: @agent,
          context: @context,
          creative: @creative
        )

        handler.handle(@error)

        @task.reload
        assert_equal "pending_approval", @task.status
        assert_equal "update_creative", @task.pending_tool_call["tool_name"]
      end
    end
  end
end
