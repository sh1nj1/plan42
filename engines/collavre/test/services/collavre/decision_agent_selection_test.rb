# frozen_string_literal: true

require "test_helper"

module Collavre
  class DecisionAgentSelectionTest < ActiveSupport::TestCase
    setup do
      @human = users(:one)
      @chat = users(:ai_bot)
      @judge = users(:two)
      @judge.update!(llm_vendor: "typesafe", llm_model: "jev-latest", searchable: true)
      @parent = Creative.create!(description: "Decision parent", user: @human)
      @child = Creative.create!(description: "Decision task", user: @human, parent: @parent)
      CreativeShare.create!(creative: @parent, user: @chat, permission: :write)
      @judge_share = CreativeShare.create!(creative: @parent, user: @judge, permission: :feedback)
    end

    test "native decisions are preferred and feedback permission includes write" do
      job = TriggerLoopCheckJob.new
      assert_equal @judge, job.send(:pick_fallback_agent, @child)
      assert_equal @chat, @child.find_ai_agent(:feedback, capability: :chat)
      assert_equal @judge, @child.find_ai_agent(:feedback, capability: :judge)
    end

    test "read-only and locally revoked native agents cannot judge" do
      @judge_share.update!(permission: :read)
      assert_equal @chat, TriggerLoopCheckJob.new.send(:pick_fallback_agent, @child)
      @judge_share.update!(permission: :write)
      CreativeShare.create!(creative: @child, user: @judge, permission: :no_access)
      assert_nil @child.find_ai_agent(:feedback, capability: :judge)
    end

    test "nearest native share wins across agents" do
      near_judge = users(:three)
      near_judge.update!(llm_vendor: "typesafe", llm_model: "jev-preview")
      CreativeShare.create!(creative: @child, user: near_judge, permission: :feedback)
      assert_equal near_judge, @child.find_ai_agent(:feedback, capability: :judge)
    end

    test "chat fallback verifier prefers a different authorized agent" do
      @judge_share.update!(permission: :read)
      other = users(:three)
      other.update!(llm_vendor: "google", llm_model: "test")
      share = CreativeShare.create!(creative: @child, user: other, permission: :feedback)
      job = TriggerLoopVerifyJob.new
      assert_equal other, job.send(:pick_verifier_agent, @child, @chat.id)
      share.update!(permission: :read)
      assert_equal @chat, job.send(:pick_verifier_agent, @child, @chat.id)
    end

    test "native verifier prefers another native agent over self" do
      @chat.update!(llm_vendor: "openai")
      assert_equal @judge, TriggerLoopVerifyJob.new.send(:pick_verifier_agent, @child, @chat.id)
      @judge_share.update!(permission: :read)
      assert_equal @chat, TriggerLoopVerifyJob.new.send(:pick_verifier_agent, @child, @chat.id)
    end

    test "trigger execution ignores judgment-only agents with write permission" do
      @judge_share.update!(permission: :write)
      assert_equal @chat, TriggerLoopCheckJob.new.send(:find_trigger_agent, @child)
      assert_equal @chat, DropTriggerJob.new.send(:find_trigger_agent, @child)
    end

    test "queued judgment-only agent is rejected at execution" do
      task = Task.create!(name: "Chat task", agent: @judge, creative: @child, status: "pending")
      AiAgentJob.new.perform(task)
      assert_equal "cancelled", task.reload.status
    end

    test "judgment-only agents cannot be mentioned or routed for chat" do
      assert_not_includes User.mentionable_for(@child), @judge
      assert_includes User.mentionable_for(@child), @human
      context = { "creative" => { "id" => @child.id } }
      assert_not Orchestration::Matcher.permits_creative_access?(context, @judge)
      assert_equal :rejected, AiAgentJob.new.perform(@judge.id, "comment_created", context)
    end

    test "native incomplete reasons use an authorized chat agent without changing the verdict" do
      task = Task.new(creative: @child, agent: @chat)
      client = Object.new
      client.define_singleton_method(:chat) { |*| "PR still missing" }
      AiClient.stub(:new, client) do
        reason = TriggerLoopVerifyJob.new.send(:incomplete_reason, { "source" => "judge" }, "Task", task)
        assert_equal "PR still missing", reason
      end
    end

    test "chat reason avoids a second call and missing chat reason is localized" do
      task = Task.new(creative: @child, agent: @chat)
      job = TriggerLoopVerifyJob.new
      AiClient.stub(:new, ->(*) { flunk "Must not request a second chat judgment" }) do
        assert_equal "Missing PR", job.send(:incomplete_reason, { "reason" => "Missing PR", "source" => "chat" }, "Task", task)
        assert_equal I18n.t("collavre.trigger_loop.incomplete_reason"),
          job.send(:incomplete_reason, { "source" => "chat" }, "Task", task)
      end
    end
  end
end
