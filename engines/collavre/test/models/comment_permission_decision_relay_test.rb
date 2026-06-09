# frozen_string_literal: true

require "test_helper"

module Collavre
  # A Claude Channel session suspended on a native tool-permission prompt parks
  # its in-flight dispatch as a `delegated` task carrying pending_tool_call (set
  # by /agent/notify when the 🔐 prompt is relayed). While it is parked, a human
  # comment in the topic is an allow/deny *decision*, not a new turn, and must be
  # relayed straight to the suspended agent's per-agent stream so the MCP plugin
  # can resolve the prompt.
  #
  # It must NOT be routed through the orchestrator: the delegated task holds the
  # topic's only concurrency slot (running_for_topic counts `delegated`), so a
  # decision dispatched as a competing turn would defer behind the very task it
  # is meant to unblock — a deadlock (the observed "⏳ 대기중" stall).
  class CommentPermissionDecisionRelayTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include ActionCable::TestHelper

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @user = users(:one)

      @creative = Collavre::Creative.create!(description: "Work", user: @user, progress: 0.0)
      @agent = User.create!(
        email: "perm_relay_agent@agent.collavre.local",
        name: "Claude Channel Session",
        password: "password",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        created_by_id: @user.id
      )
      @topic = @creative.topics.create!(name: "Claude session-x", user: @user)
    end

    teardown { ActiveJob::Base.queue_adapter = @original_adapter }

    def delegated_task(pending:)
      Collavre::Task.create!(
        name: "In-flight dispatch",
        status: "delegated",
        trigger_event_name: "comment_created",
        agent: @agent,
        topic_id: @topic.id,
        creative_id: @creative.id,
        pending_tool_call: pending
      )
    end

    test "human allow/deny relays to the suspended agent stream and skips orchestration" do
      delegated_task(pending: { "request_id" => "abc", "requested_at" => "t" })

      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        assert_broadcasts("agent:user:#{@agent.id}", 1) do
          @creative.comments.create!(content: "deny", user: @user, topic: @topic)
        end
      end
    end

    test "the relayed payload carries the decision content for the plugin coordinator" do
      delegated_task(pending: { "request_id" => "abc" })

      payload = nil
      capture_broadcasts("agent:user:#{@agent.id}") do
        @creative.comments.create!(content: "allow", user: @user, topic: @topic)
      end.tap { |msgs| payload = msgs.first }

      assert_equal "dispatch", payload["type"]
      assert_nil payload["task_id"], "task_id must be nil so the plugin does not complete the in-flight task"
      assert_equal "allow", payload.dig("comment", "content")
      assert_equal @topic.id, payload.dig("comment", "topic_id")
    end

    test "human comment does NOT relay when the delegated task has no pending_tool_call" do
      delegated_task(pending: nil)

      assert_no_broadcasts("agent:user:#{@agent.id}") do
        @creative.comments.create!(content: "deny", user: @user, topic: @topic)
      end
    end
  end
end
