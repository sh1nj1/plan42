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

    test "chat job resolver skips judgment-only pins policies and shared agents" do
      topic = @child.topics.create!(name: "Summary", user: @human, primary_agent: @judge)
      resolver = Object.new.extend(AiAgentResolvable)
      policy = Struct.new(:arbitration_config).new({ "primary_agent_id" => @judge.id })
      shares = [ @judge_share, CreativeShare.find_by!(creative: @parent, user: @chat) ]
      Orchestration::PolicyResolver.stub(:new, policy) do
        @child.effective_origin.stub(:all_shared_users, shares) do
          assert_equal @chat, resolver.send(:resolve_ai_agent, @child, topic.id)
          topic.update!(primary_agent: nil)
          assert_equal @chat, resolver.send(:resolve_ai_agent, @child, topic.id)
          topic.update!(primary_agent: @chat)
          assert_equal @chat, resolver.send(:resolve_ai_agent, @child, topic.id)
          assert_equal @chat, resolver.send(:resolve_ai_agent, @child, nil)
        end
      end
    end

    test "capability-only vendors are excluded from chat assignment surfaces" do
      capabilities = AiClient.vendor_capabilities.dup
      AiClient.stub(:vendor_capabilities, capabilities) do
        AiClient.register_vendor_capabilities("acme", capabilities: [ :judge ])
        @judge.update!(llm_vendor: "acme", creator: @human)
        assert_not_includes AiClient.vendor_options.map(&:last), "acme"
        assert_not @judge.supports?(:chat)
        assert_not_includes User.chat_capable, @judge
        assert_not_includes User.mentionable_for(@child), @judge
        editor = Workflow::Editor.new(@parent, @human)
        assert_not_includes editor.as_json[:agents].pluck(:id), @judge.id
        assert_includes User.chat_capable, @chat
      end
    end

    test "chat assignment scopes normalize stored vendor names" do
      [ "Typesafe", " typesafe " ].each do |vendor|
        @judge.update!(llm_vendor: vendor, creator: @human)
        assert_not @judge.supports?(:chat)
        assert_not_includes User.chat_capable, @judge
        assert_not_includes User.mentionable_for(@child), @judge
        assert_not_includes Workflow::Editor.new(@parent, @human).as_json[:agents].pluck(:id), @judge.id
      end
    end

    test "changing to a judgment-only vendor releases all primary pins" do
      topics = [ @parent, @child ].map do |creative|
        creative.topics.create!(name: "Pinned", user: @human, primary_agent: @chat)
      end
      other_topic = @parent.topics.create!(name: "Other", user: @human, primary_agent: @judge)
      @chat.update!(llm_vendor: "google")
      topics.each { |topic| assert_equal @chat.id, topic.reload.primary_agent_id }
      @chat.update!(llm_vendor: " Typesafe ")
      topics.each { |topic| assert_nil topic.reload.primary_agent_id }
      assert_equal @judge.id, other_topic.reload.primary_agent_id
    end

    test "released primary pin allows ambient routing to another chat agent" do
      other = users(:three)
      other.update!(llm_vendor: "google", routing_expression: 'event_name == "comment_created"')
      CreativeShare.create!(creative: @child, user: other, permission: :feedback)
      topic = @child.topics.create!(name: "Pinned", user: @human, primary_agent: @chat)
      context = { "event_name" => "comment_created", "creative" => { "id" => @child.id },
                  "topic" => { "id" => topic.id } }
      assert_equal [ @chat ], Orchestration::Matcher.new(context).match
      @chat.update!(llm_vendor: "typesafe")
      assert_includes Orchestration::Matcher.new(context).match, other
    end

    test "failed vendor updates preserve primary pins" do
      topic = @child.topics.create!(name: "Pinned", user: @human, primary_agent: @chat)
      assert_not @chat.update(llm_vendor: "typesafe", email: nil)
      assert_equal @chat.id, topic.reload.primary_agent_id
    end

    test "missing-agent translations require chat support and write permission" do
      en = I18n.t("collavre.drop_trigger.no_agent", locale: :en, parent_description: "Stage")
      ko = I18n.t("collavre.drop_trigger.no_agent", locale: :ko, parent_description: "Stage")
      assert_includes en, "chat-capable AI agent with write permission"
      assert_includes ko, "대화 가능한 AI 에이전트"
      assert_includes ko, "쓰기 권한"
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
      @chat.update!(llm_vendor: "openai", llm_model: "gpt-6-luna")
      assert_equal @judge, TriggerLoopVerifyJob.new.send(:pick_verifier_agent, @child, @chat.id)
      @judge_share.update!(permission: :read)
      assert_equal @chat, TriggerLoopVerifyJob.new.send(:pick_verifier_agent, @child, @chat.id)
    end

    test "OpenAI chat agents are not preferred as native verifiers" do
      @chat.update!(llm_vendor: "openai", llm_model: "gpt-4o")
      assert @chat.supports?(:chat)
      assert_not @chat.supports?(:judge)
      assert_equal @judge, TriggerLoopCheckJob.new.send(:pick_fallback_agent, @child)
      assert_equal @judge, TriggerLoopVerifyJob.new.send(:pick_verifier_agent, @child, @judge.id)

      @judge_share.update!(permission: :read)
      assert_nil @child.find_ai_agent(:feedback, capability: :judge)
      assert_equal @chat, TriggerLoopCheckJob.new.send(:pick_fallback_agent, @child)
      assert_equal @chat, TriggerLoopVerifyJob.new.send(:pick_verifier_agent, @child, @judge.id)
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

    test "native explanation failure keeps the incomplete verdict" do
      task = Task.new(creative: @child, agent: @chat)
      client = Object.new
      client.define_singleton_method(:chat) { |*| raise "Explanation unavailable" }
      AiClient.stub(:new, client) do
        assert_equal I18n.t("collavre.trigger_loop.incomplete_reason"),
          TriggerLoopVerifyJob.new.send(:incomplete_reason, { "source" => "judge" }, "Task", task)
      end
    end

    test "missing-agent notice requires a writable chat agent" do
      CreativeShare.where(creative: @parent, user: @chat).destroy_all
      @judge_share.update!(permission: :write)
      assert_difference -> { @parent.comments.count }, 1 do
        Creatives::DropTriggerMissingAgentNotifier.new(creative: @parent).call
      end
    end

    test "manual restart context selects chat rather than judgment-only agent" do
      @judge_share.update!(permission: :write)
      command = Creatives::TriggerActionCommand.new(creative: @child, user: @human, action: "resume")
      assert_equal @chat, command.send(:trigger_context).last
    end

    test "human reply resumes loop with a chat agent" do
      @parent.update!(data: { "trigger" => { "on_child_enter" => true } })
      @judge_share.update!(permission: :write)
      topic = @child.topics.create!(name: "Drop Trigger", user: @human)
      @child.update!(data: { "trigger" => { "loop" => { "state" => "awaiting_user", "trigger_topic_id" => topic.id } } })
      reply = @child.comments.create!(content: "Continue", user: @human, topic: topic, skip_dispatch: true)
      SystemEvents::Dispatcher.stub(:dispatch, []) { reply.send(:resume_trigger_loop_if_awaiting) }
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      assert_includes @child.comments.order(:id).last.content, "@#{@chat.name}:"
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
