# frozen_string_literal: true

require "test_helper"

module Collavre
  # Claude Channel registers each session's topic *inside* the user's Inbox
  # creative and relies on the orchestration pipeline (Matcher → Arbiter →
  # AiAgentService) to deliver comments to the running session. The pre-existing
  # `return if creative.inbox?` guard in Comment#dispatch_to_orchestration must
  # therefore NOT short-circuit when the inbox topic has a primary_agent
  # (an agent session topic) — while still skipping ordinary inbox DMs that
  # have no agent.
  class CommentInboxDispatchTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = users(:one)

      @inbox = Collavre::Creative.create!(
        description: "Inbox",
        data: { "kind" => "inbox" },
        user: @user,
        progress: 0.0
      )

      @agent = User.create!(
        email: "inbox_dispatch_agent@agent.collavre.local",
        name: "Claude Channel Session",
        password: "password",
        llm_vendor: "anthropic",
        llm_model: "claude-code",
        routing_expression: "true",
        created_by_id: @user.id
      )

      share = Collavre::CreativeShare.find_or_create_by!(creative: @inbox, user: @agent)
      share.update!(permission: "feedback")
      Collavre::CreativeSharesCache.find_or_create_by!(
        creative_id: @inbox.id,
        user_id: @agent.id,
        permission: :feedback
      )
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    test "human comment in a registered Claude session topic dispatches to orchestration" do
      topic = @inbox.topics.create!(name: "Claude session-x", user: @user, session_id: "sess-x")
      topic.set_primary_agent!(@agent)

      assert_enqueued_with(job: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "hi", user: @user, topic: topic)
      end
    end

    # A Claude Channel ai_user can be set as an inbox topic's primary_agent via
    # TopicsController#set_primary_agent without ever registering a session (no
    # session_id). That is NOT a real session topic: the adapter stamps
    # session_topic on session_id presence, so dispatching here would route an
    # ordinary inbox thread to the live Claude session. The exception must key
    # on the registration marker (session_id), matching the adapter.
    test "human comment in an inbox topic with a Claude primary_agent but NO session_id does not dispatch" do
      topic = @inbox.topics.create!(name: "Claude agent, unregistered", user: @user)
      topic.set_primary_agent!(@agent)

      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "ordinary dm", user: @user, topic: topic)
      end
    end

    test "human comment in an inbox topic WITHOUT a primary_agent does not dispatch" do
      topic = @inbox.topics.create!(name: "Plain inbox thread", user: @user)

      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "just a note", user: @user, topic: topic)
      end
    end

    # An inbox topic may be given a primary agent that is NOT a Claude Channel
    # session (TopicsController#set_primary_agent accepts any ai_user). The inbox
    # dispatch exception must stay scoped to actual Claude Channel session topics
    # — otherwise an ordinary inbox thread leaks to the live Claude session,
    # which holds inbox-wide feedback + routing_expression="true".
    test "human comment in an inbox topic with a NON-Claude primary_agent does not dispatch" do
      other_agent = User.create!(
        email: "inbox_other_agent@agent.collavre.local",
        name: "Ordinary Inbox Agent",
        password: "password",
        llm_vendor: "anthropic",
        llm_model: "claude-3-5-sonnet",
        routing_expression: "true",
        created_by_id: @user.id
      )
      topic = @inbox.topics.create!(name: "Inbox thread with non-claude agent", user: @user)
      topic.set_primary_agent!(other_agent)

      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "ordinary dm", user: @user, topic: topic)
      end
    end
  end
end
