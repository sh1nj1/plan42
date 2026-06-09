# frozen_string_literal: true

require "test_helper"

module Collavre
  # Presence/typing-indicator lifecycle for Claude Channel (MCP) agents.
  #
  # A Claude Channel dispatch is async: the server broadcasts and returns, then
  # the reply arrives minutes later via /reply. Unlike RubyLLM agents (which
  # heartbeat agent_status from a long-running job), the Claude path has no
  # in-process loop to keep the frontend "thinking" indicator alive (the UI
  # auto-clears it after AGENT_STATUS_TIMEOUT=10s without a beat). This job is
  # that heartbeat: it re-broadcasts while the task is delegated and a session
  # is live, clears + posts a system notice when the session is gone, and stops
  # once the task is no longer delegated.
  class ClaudeChannelPresenceJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      # The suite forces the :inline adapter (config/environments/test.rb), under
      # which this job's self-re-enqueue would recurse forever. Use the :test
      # adapter here so perform_now runs the body once and records the next beat.
      @original_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = users(:one)
      @creative = creatives(:tshirt)
      @agent = User.create!(
        email: "cc-presence-test@agent.collavre.local",
        password: SecureRandom.hex(32),
        name: "Claude Presence",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        created_by_id: @user.id,
        searchable: false
      )
      @topic = @creative.topics.create!(name: "Presence Topic", user: @user)
      @task = Task.create!(
        name: "Presence Task",
        status: "delegated",
        trigger_event_name: "comment_created",
        trigger_event_payload: {
          "comment" => { "id" => 1, "content" => "Hi" },
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id }
        },
        agent: @agent,
        topic_id: @topic.id,
        creative_id: @creative.id
      )
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_queue_adapter
    end

    def make_subscription(last_seen_at:)
      AgentSubscription.create!(agent: @agent, token: SecureRandom.hex(8), last_seen_at: last_seen_at)
    end

    # Capture agent_status payloads broadcast on the comments_presence channel.
    def capture_agent_statuses
      broadcasts = []
      ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
        yield
      end
      broadcasts
        .select { |b| b[:data].is_a?(Hash) && b[:data][:agent_status].present? }
        .map { |b| b[:data][:agent_status] }
    end

    test "live session: broadcasts a working status and re-enqueues the heartbeat" do
      make_subscription(last_seen_at: Time.current)

      statuses = nil
      assert_enqueued_with(job: ClaudeChannelPresenceJob, args: [ @task.id ]) do
        statuses = capture_agent_statuses { ClaudeChannelPresenceJob.perform_now(@task.id) }
      end

      working = statuses.find { |s| %w[thinking streaming].include?(s[:status]) }
      assert_not_nil working, "expected a thinking/streaming agent_status while a live session holds the agent"
      assert_equal @agent.id, working[:id]
    end

    test "no live session: clears the indicator, posts an authorless disconnect notice, no re-enqueue" do
      before = @creative.comments.count

      statuses = nil
      assert_no_enqueued_jobs(only: ClaudeChannelPresenceJob) do
        statuses = capture_agent_statuses { ClaudeChannelPresenceJob.perform_now(@task.id) }
      end

      assert(statuses.any? { |s| s[:status] == "idle" },
             "expected idle to clear the indicator when no live session remains")
      assert_equal before + 1, @creative.comments.count, "expected one system disconnect notice comment"
      notice = @creative.comments.order(:created_at).last
      assert_nil notice.user_id, "disconnect notice should be authorless (a system message)"
    end

    test "stale session row is ignored (treated as disconnected) and reaped" do
      make_subscription(last_seen_at: (AgentSubscription::STALE_AFTER + 1.minute).ago)

      statuses = capture_agent_statuses { ClaudeChannelPresenceJob.perform_now(@task.id) }

      assert(statuses.any? { |s| s[:status] == "idle" })
      assert_not AgentSubscription.where(agent_id: @agent.id).exists?, "stale row should be reaped"
    end

    test "task no longer delegated: no broadcast, no notice, no re-enqueue" do
      make_subscription(last_seen_at: Time.current)
      @task.update!(status: "done")
      before = @creative.comments.count

      statuses = nil
      assert_no_enqueued_jobs(only: ClaudeChannelPresenceJob) do
        statuses = capture_agent_statuses { ClaudeChannelPresenceJob.perform_now(@task.id) }
      end

      assert_empty statuses
      assert_equal before, @creative.comments.count, "a completed task must not post a disconnect notice"
    end

    test "non-Claude-channel agent: no-op" do
      @task.update!(agent: users(:ai_bot))

      statuses = capture_agent_statuses { ClaudeChannelPresenceJob.perform_now(@task.id) }

      assert_empty statuses
    end
  end
end
