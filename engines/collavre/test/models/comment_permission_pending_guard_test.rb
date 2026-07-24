# frozen_string_literal: true

require "test_helper"

module Collavre
  # A Claude Channel session suspended on a native tool-permission prompt parks
  # its in-flight dispatch as a `delegated` task carrying pending_tool_call (set
  # by /agent/notify when the prompt is relayed). The allow/deny decision is made
  # by clicking the approve/deny buttons on the structured permission comment,
  # which relays the decision out-of-band (see ApprovalActions).
  #
  # While the task stays parked, an intervening human *text* comment must be
  # handed to orchestration rather than silently dropped. The scheduler then
  # *defers* it (the delegated task holds the topic's only concurrency slot, so
  # topic_max_concurrent_jobs=1 forces a queued task + "⏳ 대기중" notice), and
  # when the parked task is finalized on /reply, dequeue_next_for_topic promotes
  # that queued task and refreshes it to the latest comment. So the follow-up
  # runs as the next turn instead of being lost — defer, never drop. This matters
  # most when the local Claude TUI answers the prompt before the Collavre
  # buttons: the server still sees pending_tool_call until /reply, so dropping
  # would silently discard every follow-up posted during the rest of that
  # locally-approved tool run.
  class CommentPermissionPendingGuardTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include ActionCable::TestHelper

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @user = users(:one)

      @creative = Collavre::Creative.create!(description: "Work", user: @user, progress: 0.0)
      @agent = User.create!(
        email: "perm_guard_agent@agent.collavre.local",
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

    test "an intervening human comment is handed to orchestration (deferred, not dropped) while a permission is parked" do
      delegated_task(pending: { "request_id" => "abc", "requested_at" => "t" })

      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "what does that do?", user: @user, topic: @topic)
      end

      assert dispatched,
        "a comment posted while a permission is parked must reach orchestration so the scheduler " \
        "can defer it behind the parked task and redeliver it on /reply — not be silently dropped"
    end

    test "a follow-up posted during a locally-answered prompt is still handed to orchestration" do
      # Local Claude TUI answered the prompt, but the server still sees
      # pending_tool_call until /reply. The follow-up must still be dispatched
      # (then deferred) so it is not lost during the rest of the tool run.
      delegated_task(pending: { "request_id" => "abc", "requested_at" => "t" })

      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "also rename it while you're there", user: @user, topic: @topic)
      end

      assert dispatched,
        "a follow-up during a locally-approved tool run must not be silently dropped"
    end

    test "no decision is broadcast for a human text comment (decisions are button-driven)" do
      delegated_task(pending: { "request_id" => "abc" })

      assert_no_broadcasts("agent:user:#{@agent.id}") do
        @creative.comments.create!(content: "allow", user: @user, topic: @topic)
      end
    end

    test "a human comment dispatches normally when the delegated task has no pending_tool_call" do
      delegated_task(pending: nil)

      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "go ahead", user: @user, topic: @topic)
      end

      assert dispatched, "a comment must dispatch normally when no permission is parked"
    end

    test "the guard ignores a parked task whose agent is not a Claude Channel agent" do
      non_claude = User.create!(
        email: "non_claude_agent@agent.collavre.local",
        name: "Other AI",
        password: "password",
        llm_vendor: "openai",
        llm_model: "gpt-4",
        created_by_id: @user.id
      )
      Collavre::Task.create!(
        name: "In-flight dispatch",
        status: "delegated",
        trigger_event_name: "comment_created",
        agent: non_claude,
        topic_id: @topic.id,
        creative_id: @creative.id,
        pending_tool_call: { "request_id" => "abc" }
      )

      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "hello", user: @user, topic: @topic)
      end

      assert dispatched, "the guard is specific to Claude Channel permission prompts"
    end
  end
end
