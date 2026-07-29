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
          agent: @agent,
          topic_id: @creative.main_topic.id
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
        before_count = @creative.comments.count
        handler.handle(@error, summary: summary)

        assert_equal before_count + 1, @creative.comments.reload.count
        comment = @creative.comments.order(:id).last
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

        before_count = @creative.comments.count
        handler.handle(@error, summary: nil)

        assert_equal before_count + 1, @creative.comments.reload.count
        comment = @creative.comments.order(:id).last
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

        before_count = @creative.comments.count
        handler.handle(@error)

        assert_equal before_count + 1, @creative.comments.reload.count
        comment = @creative.comments.order(:id).last
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

        comment = @creative.comments.order(:id).last
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

      # An "idle" here read as "task over" to the client, which dropped the task
      # and stopped polling, so the pending_approval status set below was never
      # seen and the Stop button vanished on the one turn waiting on the user.
      test "broadcasts pending_approval, not idle, and only after the task is updated" do
        handler = ApprovalHandler.new(
          task: @task,
          agent: @agent,
          context: @context,
          creative: @creative
        )

        statuses = capture_agent_statuses { handler.handle(@error) }

        assert_equal [ "pending_approval" ], statuses.map { |s| s[:status] }
        assert_equal [ @task.id ], statuses.map { |s| s[:task_id] }
        assert_equal [ @task.topic_id ], statuses.map { |s| s[:topic_id] },
                     "the client routes the indicator by topic, so a replayed pause needs one"
      end

      test "the broadcast task is already pending_approval when the payload goes out" do
        handler = ApprovalHandler.new(
          task: @task,
          agent: @agent,
          context: @context,
          creative: @creative
        )

        observed = nil
        capture_agent_statuses(during: -> { observed = Collavre::Task.find(@task.id).status }) do
          handler.handle(@error)
        end

        assert_equal "pending_approval", observed,
                     "a client polling on receipt must not read a status the payload contradicts"
      end

      private

      # Collect the agent_status payloads broadcast while the block runs. `during`
      # runs at broadcast time, for asserting what the DB says at that instant.
      def capture_agent_statuses(during: nil)
        payloads = []
        CommentsPresenceChannel.stub(:broadcast_agent_status, lambda { |_creative_id, **kwargs|
          payloads << kwargs
          during&.call
        }) do
          yield
        end
        payloads
      end
    end
  end
end
