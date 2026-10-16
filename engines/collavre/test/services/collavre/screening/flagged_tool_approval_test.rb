# frozen_string_literal: true

require "test_helper"

module Collavre
  class FlaggedToolApprovalTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @agent = users(:ai_bot)
      @agent.update!(created_by_id: @owner.id)
      @task = Task.create!(name: "Flagged", status: "running", agent: @agent)
      @call = RubyLLM::ToolCall.new(id: "call-1", name: "creative_retrieval_service", arguments: { "id" => 1 })
    end

    def check(flagged)
      client = AiClient.new(vendor: "google", model: "gemini", system_prompt: nil,
                            context: { task: @task, screening_flagged: flagged })
      client.send(:check_tool_approval!, @call)
    end

    test "a flagged turn needs the agent owner's approval for any tool" do
      error = assert_raises(ApprovalPendingError) { check(true) }
      assert_equal @owner, error.approver
      assert_equal "creative_retrieval_service", error.tool_name
    end

    test "an unflagged turn keeps the normal tool policy" do
      assert_nil check(false)
      assert_nil check(nil)
    end

    test "the approval comment goes to the error's approver ahead of the creative owner" do
      creative = Creative.create!(description: "Someone else's", user: users(:two))
      error = ApprovalPendingError.new(tool_call: @call, task: @task, approver: @owner)
      AiAgent::ApprovalHandler.new(task: @task, agent: @agent, context: {}, creative: creative).handle(error)
      assert_equal @owner, creative.comments.last.approver
      assert @task.reload.pending_approval?
    end

    test "Screening.texts_for keeps only text others could have written" do
      messages = [
        { role: "user", kind: :creative_context, parts: [ { text: "ctx" } ] },
        { role: "user", kind: :chat_history, author_id: @owner.id, parts: [ { text: "owner" } ] },
        { role: "user", kind: :chat_history, author_id: 999, parts: [ { text: "other" }, { image: "blob" } ] },
        { role: "model", kind: :chat_history, parts: [ { text: "agent" } ] },
        { role: "user", text: "plain" }
      ]
      assert_equal [ { source: "creative_context", text: "ctx" }, { source: "chat_history", text: "other" },
                     { source: "user", text: "plain" } ],
                   Screening.texts_for(messages, owner_id: @owner.id)
      assert_equal 2, Screening.texts_for(messages, owner_id: nil).count { |t| t[:source] == "chat_history" }
    end
  end
end
