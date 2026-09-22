# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class ResumeContextTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:ai_bot)
        @creative = creatives(:tshirt)
        @comment = @creative.comments.create!(content: "Write the report", user: @user, skip_dispatch: true)
        @resume = {
          "reason" => "server_restart", "attempt" => 2,
          "partial_reply" => "First half", "actions" => [ "reply_created (done)" ]
        }
        @context = {
          "comment" => { "id" => @comment.id, "content" => "Write the report" },
          "creative" => { "id" => @creative.id },
          ResumeContext::KEY => @resume
        }
      end

      test "renders why the turn stopped, what was shown and what was done" do
        note = ResumeContext.render(@context)

        assert_includes note, I18n.t("collavre.orchestration.suspension.resume_reasons.server_restart")
        assert_includes note, I18n.t("collavre.orchestration.suspension.resume_partial_reply")
        assert_includes note, "First half"
        assert_includes note, "- reply_created (done)"
      end

      test "renders nothing for a turn that was never suspended" do
        assert_nil ResumeContext.render(@context.except(ResumeContext::KEY))
        assert_nil ResumeContext.render(nil)
        assert_equal "text", ResumeContext.prepend_to("text", {})
      end

      test "omits empty sections and falls back to the raw reason" do
        note = ResumeContext.render(ResumeContext::KEY => { "reason" => "mystery" })

        assert_includes note, "mystery"
        assert_not_includes note, I18n.t("collavre.orchestration.suspension.resume_partial_reply")
        assert_not_includes note, I18n.t("collavre.orchestration.suspension.resume_actions")
      end

      test "capture keeps an earlier partial reply and the original trigger" do
        task = Task.create!(
          name: "Turn", status: "running", agent: @agent, resume_count: 1,
          trigger_event_payload: @context.merge(
            "comment" => { "id" => 999 },
            ResumeContext::KEY => { "partial_reply" => "Earlier", "trigger_comment_id" => @comment.id }
          ),
          pending_tool_call: { "tool_name" => "creative_update_service", "approved" => true }
        )

        captured = ResumeContext.capture(task, reason: :quota)

        assert_equal "quota", captured["reason"]
        assert_equal 2, captured["attempt"]
        assert_equal "Earlier", captured["partial_reply"]
        assert_equal @comment.id, captured["trigger_comment_id"]
        assert_equal [ "tool creative_update_service (approved)" ], captured["actions"]
      end

      test "the LLM trigger carries the resume note" do
        result = AiAgent::MessageBuilder.new(agent: @agent, context: @context, original_comment: @comment).build
        trigger = result[:messages].find { |m| m[:kind] == :trigger }

        assert_includes trigger[:parts].first[:text], "First half"
        assert trigger[:parts].first[:text].end_with?("Write the report")
      end

      test "the Claude Channel dispatch carries the resume note" do
        agent = User.create!(email: "resume-cc@agent.collavre.local", password: SecureRandom.hex(16),
                             name: "Resume CC", llm_vendor: "anthropic", llm_model: "claude-code",
                             created_by_id: @user.id, searchable: false)
        topic = @creative.topics.create!(name: "Resume CC topic", user: @user)
        broadcasts = []

        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << data } do
          AiAgent::ClaudeChannelAdapter.new(agent: agent, context: @context.merge("topic" => { "id" => topic.id })).deliver
        end

        content = broadcasts.first[:comment][:content]
        assert_includes content, "First half"
        assert content.end_with?("Write the report")
      end

      test "a dispatch restored from a suspended turn does not inherit its resume note" do
        assert_includes DeliveryRecord::TURN_SCOPED_KEYS, ResumeContext::KEY
      end
    end
  end
end
