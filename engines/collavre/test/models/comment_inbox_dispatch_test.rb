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

    test "human comment in an inbox topic WITH a primary_agent dispatches to orchestration" do
      topic = @inbox.topics.create!(name: "Claude session-x", user: @user)
      topic.set_primary_agent!(@agent)

      assert_enqueued_with(job: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "hi", user: @user, topic: topic)
      end
    end

    test "human comment in an inbox topic WITHOUT a primary_agent does not dispatch" do
      topic = @inbox.topics.create!(name: "Plain inbox thread", user: @user)

      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "just a note", user: @user, topic: topic)
      end
    end
  end
end
