# frozen_string_literal: true

require "test_helper"

module Collavre
  # A message that renders an approval button (pending) or an approved/denied
  # status label (승인됨/거부됨, decided) in the chat list carries an `action`
  # JSON payload. Such a message is a HUMAN decision surface and must NEVER be
  # dispatched to an AI agent — regardless of who authored it or whether it has
  # already been decided.
  #
  # The invariant is content-based (Comment#approval_action? == action.present?),
  # not author-based: before this filter, an approval comment was only skipped
  # incidentally because an AI authored it (user&.ai_user?), leaving gaps for
  # human-authored action comments and the @mention re-dispatch (A2A) path.
  #
  # These tests pin the predicate and both dispatch seams.
  class CommentApprovalDispatchTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    # Representative action payloads for the three approval-message flavors, all
    # of which render the approve button / 승인됨 label in the chat list.
    ACTION_PAYLOADS = {
      execute_tool: { "action" => "execute_tool", "tool_name" => "write_file" },
      approve_tool: { "actions" => [ { "action" => "approve_tool", "tool_name" => "bash" } ] },
      claude_channel_permission: { "action" => "claude_channel_permission", "tool_name" => "Bash" }
    }.freeze

    setup do
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = users(:one)

      # Inbox + registered Claude session topic: the proven recipe where an
      # ordinary human comment DOES dispatch to an agent, so a non-dispatch is
      # attributable to the approval filter, not a missing match.
      @inbox = Collavre::Creative.create!(
        description: "Inbox",
        data: { "kind" => "inbox" },
        user: @user,
        progress: 0.0
      )

      @agent = User.create!(
        email: "approval_dispatch_agent@agent.collavre.local",
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

      @topic = @inbox.topics.create!(name: "Claude session-approval", user: @user, session_id: "sess-approval")
      @topic.set_primary_agent!(@agent)
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    # --- Predicate: approval_action? == action.present? ------------------------

    test "approval_action? is true for every flavor, both pending and decided" do
      ACTION_PAYLOADS.each do |flavor, payload|
        pending = @inbox.comments.create!(
          content: "needs approval (#{flavor})",
          user: @user, topic: @topic,
          action: JSON.generate(payload), approver: @user, skip_dispatch: true
        )
        assert pending.approval_action?, "pending #{flavor} should be approval_action?"

        decided = @inbox.comments.create!(
          content: "decided (#{flavor})",
          user: @user, topic: @topic,
          action: JSON.generate(payload), approver: @user,
          action_executed_at: Time.current, action_executed_by: @user,
          skip_dispatch: true
        )
        assert decided.approval_action?, "decided #{flavor} should still be approval_action?"
      end
    end

    test "approval_action? is false for a plain comment" do
      plain = @inbox.comments.create!(
        content: "just chatting", user: @user, topic: @topic, skip_dispatch: true
      )
      refute plain.approval_action?
    end

    # --- Seam 1: Comment#dispatch_to_orchestration -----------------------------

    test "a plain human comment DOES dispatch (control)" do
      assert_enqueued_with(job: Collavre::AiAgentJob) do
        @inbox.comments.create!(content: "hi agent", user: @user, topic: @topic)
      end
    end

    test "an approval-action comment does NOT dispatch, pending or decided, any flavor" do
      ACTION_PAYLOADS.each do |flavor, payload|
        assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
          @inbox.comments.create!(
            content: "pending #{flavor}", user: @user, topic: @topic,
            action: JSON.generate(payload), approver: @user
          )
        end

        assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
          @inbox.comments.create!(
            content: "decided #{flavor}", user: @user, topic: @topic,
            action: JSON.generate(payload), approver: @user,
            action_executed_at: Time.current, action_executed_by: @user
          )
        end
      end
    end

    # --- Seam 2: AiAgent::A2aDispatcher#dispatch -------------------------------

    test "A2A does NOT re-dispatch an approval-action reply that @mentions an agent" do
      mention = "@#{@agent.name} please continue"

      reply = @inbox.comments.create!(
        content: mention, user: @agent, topic: @topic,
        action: JSON.generate(ACTION_PAYLOADS[:execute_tool]), approver: @user,
        skip_dispatch: true
      )

      dispatcher = Collavre::AiAgent::A2aDispatcher.new(
        agent: @agent,
        reply_comment: reply,
        context: { "creative" => { "id" => reply.creative_id }, "topic" => { "id" => reply.topic_id } }
      )

      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        dispatcher.dispatch
      end
    end
  end
end
