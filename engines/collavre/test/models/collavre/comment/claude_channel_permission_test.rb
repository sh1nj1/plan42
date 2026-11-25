# frozen_string_literal: true

require "test_helper"

module Collavre
  class Comment
    class ClaudeChannelPermissionTest < ActiveSupport::TestCase
      include ActionCable::TestHelper

      setup do
        @user = users(:one)
        @creative = Collavre::Creative.create!(description: "Work", user: @user, progress: 0.0)
        @agent = User.create!(
          email: "ccp_agent@agent.collavre.local",
          name: "Claude Channel Session",
          password: "password",
          llm_vendor: "anthropic",
          llm_model: "claude-code",
          created_by_id: @user.id
        )
        @topic = @creative.topics.create!(name: "Claude session-x", user: @user)
      end

      def permission_comment(request_id: "req-1", decided: nil)
        payload = {
          "action" => Comment::ClaudeChannelPermission::ACTION_TYPE,
          "request_id" => request_id,
          "tool_name" => "Bash",
          "arguments" => { "command" => "ls" }
        }
        payload["decision"] = decided if decided
        Comment.create!(
          creative: @creative,
          topic: @topic,
          user: @agent,
          approver: @user,
          content: "needs approval",
          action: JSON.pretty_generate(payload),
          action_executed_at: decided ? Time.current : nil,
          skip_default_user: true,
          skip_dispatch: true
        )
      end

      def approval_request_comment(request_id: "approval-1", question: "Deploy to production?")
        Comment.create!(
          creative: @creative,
          topic: @topic,
          user: @agent,
          approver: @user,
          content: question,
          action: JSON.pretty_generate({
            "action" => Comment::ClaudeChannelPermission::ACTION_TYPE,
            "kind" => Comment::ClaudeChannelPermission::KIND_APPROVAL_REQUEST,
            "request_id" => request_id,
            "question" => question
          }),
          skip_default_user: true,
          skip_dispatch: true
        )
      end

      test "claude_channel_permission? is true only for the permission action type" do
        assert permission_comment.claude_channel_permission?

        native = Comment.create!(
          creative: @creative, topic: @topic, user: @agent,
          content: "x", action: JSON.pretty_generate({ "action" => "execute_tool" }),
          skip_default_user: true, skip_dispatch: true
        )
        refute native.claude_channel_permission?

        plain = Comment.create!(creative: @creative, topic: @topic, user: @user, content: "hi")
        refute plain.claude_channel_permission?
      end

      test "request_id is read from the action payload" do
        assert_equal "req-42", permission_comment(request_id: "req-42").claude_channel_permission_request_id
      end

      test "decide! stamps execution and records the decision in the payload" do
        comment = permission_comment

        comment.decide_claude_channel_permission!(:deny, by: @user)

        comment.reload
        assert comment.action_executed_at.present?
        assert_equal @user.id, comment.action_executed_by_id
        assert comment.claude_channel_permission_denied?
      end

      test "decide! is idempotent — a second decision raises AlreadyDecided" do
        comment = permission_comment
        comment.decide_claude_channel_permission!(:allow, by: @user)

        assert_raises(Comment::ClaudeChannelPermission::AlreadyDecided) do
          comment.decide_claude_channel_permission!(:deny, by: @user)
        end
      end

      test "an approved comment is not marked denied" do
        comment = permission_comment
        comment.decide_claude_channel_permission!(:allow, by: @user)
        refute comment.reload.claude_channel_permission_denied?
      end

      test "broadcast relays request_id + behavior to the authoring agent's stream" do
        comment = permission_comment(request_id: "req-7")

        payload = capture_broadcasts("agent:user:#{@agent.id}") do
          assert comment.broadcast_claude_channel_permission_decision("allow")
        end.first

        assert_equal "permission_decision", payload["type"]
        assert_equal "req-7", payload["request_id"]
        assert_equal "allow", payload["behavior"]
        assert_equal @agent.id, payload["agent_id"]
      end

      test "an agent-initiated approval request is distinguished from a relayed tool prompt" do
        assert approval_request_comment.claude_channel_approval_request?
        assert approval_request_comment.claude_channel_permission?, "it rides the same decision rail"
        refute permission_comment.claude_channel_approval_request?
      end

      test "decide! persists the approver's reason alongside the decision" do
        comment = approval_request_comment

        comment.decide_claude_channel_permission!(:deny, by: @user, reason: "  too risky  ")

        comment.reload
        assert comment.claude_channel_permission_denied?
        assert_equal "too risky", comment.claude_channel_permission_reason
      end

      test "a blank reason is not persisted" do
        comment = approval_request_comment
        comment.decide_claude_channel_permission!(:allow, by: @user, reason: "   ")
        assert_nil comment.reload.claude_channel_permission_reason
      end

      test "an approval decision relays the reason and the decider to the blocked agent" do
        comment = approval_request_comment(request_id: "approval-7")

        payload = capture_broadcasts("agent:user:#{@agent.id}") do
          assert comment.broadcast_claude_channel_permission_decision(
            "deny", reason: "not now", decided_by: @user
          )
        end.first

        assert_equal "approval-7", payload["request_id"]
        assert_equal "deny", payload["behavior"]
        assert_equal "not now", payload["reason"]
        assert_equal @user.id, payload["decided_by"]
        assert_equal @user.display_name, payload["decided_by_name"]
      end

      test "a relayed tool prompt's broadcast payload is unchanged (no reason/decider keys)" do
        payload = capture_broadcasts("agent:user:#{@agent.id}") do
          permission_comment(request_id: "req-9").broadcast_claude_channel_permission_decision("allow")
        end.first

        assert_equal %w[type request_id behavior agent_id].sort, payload.keys.sort
      end

      test "the resubscribe replay redelivers the complete approval decision" do
        comment = approval_request_comment(request_id: "approval-replay")
        comment.decide_claude_channel_permission!(:allow, by: @user, reason: "go ahead")

        payload = capture_broadcasts("agent:user:#{@agent.id}") do
          assert comment.rebroadcast_claude_channel_permission_decision
        end.first

        assert_equal "allow", payload["behavior"]
        assert_equal "go ahead", payload["reason"]
        assert_equal @user.id, payload["decided_by"]
      end

      test "replay finds an approval request by its namespaced request_id" do
        comment = approval_request_comment(request_id: "approval-abc")
        comment.decide_claude_channel_permission!(:deny, by: @user, reason: "no")

        payload = capture_broadcasts("agent:user:#{@agent.id}") do
          Comment.replay_claude_channel_permission_decisions_for(@agent.id, [ "approval-abc" ])
        end.first

        assert_equal "approval-abc", payload["request_id"]
        assert_equal "no", payload["reason"]
      end
    end
  end
end
