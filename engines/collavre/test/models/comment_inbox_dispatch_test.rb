# frozen_string_literal: true

require "test_helper"

module Collavre
  # Inbox dispatch policy: only the System topic (alarms/notifications) is
  # silenced; every other inbox topic dispatches exactly like a normal topic
  # (Comment#dispatch_to_orchestration gates on inbox_system_topic?).
  #
  # The catch: a live Claude Channel session agent holds inbox-wide :feedback +
  # routing_expression="true", so it would otherwise be matched onto every inbox
  # topic. Orchestration::Matcher confines it to its own registered session
  # topic, so ordinary inbox topics are never absorbed by a live session. These
  # tests pin both halves: session topics still deliver to the running session,
  # and ordinary inbox threads never leak into it.
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
    # session_id). The comment now dispatches (non-System topic), but the Matcher
    # confines the live session agent to topics carrying a session_id — so this
    # unregistered topic still produces no AI turn. session_id is the registration
    # marker the adapter (ClaudeChannelAdapter#session_topic?) keys on too.
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

    # Leak guard: the live Claude session agent from setup (inbox-wide feedback +
    # routing_expression="true") must NOT be matched onto an ordinary inbox topic,
    # even one given its own, different primary agent. The other agent here holds
    # no feedback on the inbox, so it isn't matched either — leaving zero AI turns.
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

    # --- Non-System inbox topics are ordinary conversation surfaces ---
    #
    # Only Inbox#System carries alarms/notifications (stuck recovery, share
    # notices) and must stay silent. Every OTHER inbox topic — Main, Content,
    # user threads — is treated EXACTLY like a normal (non-inbox) topic: an AI
    # agent that holds feedback on the creative dispatches there as usual.

    # A normal (non-Claude-session) AI agent that holds feedback on the inbox,
    # mirroring how an agent added to an ordinary topic is set up.
    def create_shared_inbox_agent(name:, email:)
      agent = User.create!(
        email: email,
        name: name,
        password: "password",
        llm_vendor: "anthropic",
        llm_model: "claude-3-5-sonnet",
        routing_expression: "true",
        created_by_id: @user.id
      )
      share = Collavre::CreativeShare.find_or_create_by!(creative: @inbox, user: agent)
      share.update!(permission: "feedback")
      Collavre::CreativeSharesCache.find_or_create_by!(
        creative_id: @inbox.id,
        user_id: agent.id,
        permission: :feedback
      )
      agent
    end

    test "human comment in an ordinary inbox topic (Main) dispatches like a normal topic" do
      agent = create_shared_inbox_agent(
        name: "Inbox Main Agent", email: "inbox_main_agent@agent.collavre.local"
      )
      topic = @inbox.main_topic(fallback_user: @user)
      topic.set_primary_agent!(agent)

      assert_enqueued_with(job: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "hello agent", user: @user, topic: topic)
      end
    end

    test "human comment in the inbox System topic does NOT dispatch (alarms stay silent)" do
      agent = create_shared_inbox_agent(
        name: "Inbox System Agent", email: "inbox_system_agent@agent.collavre.local"
      )
      system_topic = @inbox.system_topic(fallback_user: @user)
      system_topic.set_primary_agent!(agent)

      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "a notification-ish note", user: @user, topic: system_topic)
      end
    end
  end
end
