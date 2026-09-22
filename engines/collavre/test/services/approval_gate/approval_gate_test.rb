# frozen_string_literal: true

require "test_helper"

class ApprovalGateTest < ActiveSupport::TestCase
  setup do
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user = users(:one)
    @agent = users(:ai_bot)
    @creative = creatives(:tshirt)
    @creative.update!(user: @user)
    @task = Collavre::Task.create!(name: "Approval", status: "running", agent: @agent,
      creative: @creative, topic_id: @creative.main_topic.id,
      trigger_event_name: "comment_created", trigger_event_payload: {
        "creative" => { "id" => @creative.id }, "comment" => { "user_id" => @user.id }
      })
    @call = RubyLLM::ToolCall.new(id: "gate-1", name: "approval_request", arguments: { "question" => "Deploy?" })
    @chat = RubyLLM.context { |config| config.openai_api_key = "test" }.chat(model: "gpt-4.1", provider: :openai, assume_model_exists: true)
    @chat.add_message(role: :user, content: "Make a plan")
    @chat.add_message(role: :assistant, content: nil, tool_calls: { @call.id => @call })
    @client = Collavre::AiClient.new(vendor: "openai", model: "gpt-4.1", system_prompt: nil, context: { task: @task }, log_interactions: false)
    @client.instance_variable_set(:@conversation, @chat)
  end

  teardown do
    ActiveJob::Base.queue_adapter = @old_adapter
  end

  def pause(call = @call)
    error = assert_raises(Collavre::ApprovalGatePendingError) { @client.send(:check_tool_approval!, call) }
    Collavre::AiAgent::ApprovalGateHandler.new(task: @task, agent: @agent,
      context: @task.trigger_event_payload, creative: @creative).handle(error)
    @creative.comments.order(:id).last
  end

  test "direct request pauses and records exact call without dispatching approval comment" do
    comment = pause
    assert @task.reload.pending_approval?
    assert_equal "gate-1", @task.pending_tool_call["tool_call_id"]
    assert_equal @user, comment.approver
    assert_equal "Deploy?", comment.content
    assert_equal @task.topic_id, comment.topic_id
    assert comment.approval_action?
    assert comment.approval_gate?
    assert_nil comment.task_id
    assert_equal "approval_request", Collavre::Tools::ApprovalRequestService.tool_metadata[:name]
    refute Collavre::Tools::ApprovalRequestService.requires_approval?
  end

  test "meta tool run uses original outer call id" do
    call = RubyLLM::ToolCall.new(id: "meta-1", name: "meta_tool", arguments: {
      "action" => "run", "tool_name" => "approval_request", "arguments" => { "question" => "Proceed?" }
    })
    comment = pause(call)
    assert_equal "meta-1", @task.reload.pending_tool_call["tool_call_id"]
    assert_equal "meta_tool", @task.pending_tool_call["tool_name"]
    assert_equal "Proceed?", comment.content
    assert_nil @client.send(:approval_gate_arguments, RubyLLM::ToolCall.new(id: "search", name: "meta_tool", arguments: { "action" => "get", "tool_name" => "approval_request" }))
    assert_nil @client.send(:approval_gate_arguments, RubyLLM::ToolCall.new(id: "other", name: "other"))
  end

  %w[approved denied].each do |decision|
    test "#{decision} returns the human decision to the original call" do
      comment = pause
      assert_enqueued_with(job: Collavre::ApprovalGateResumeJob, args: [ @task.id, @call.id ]) do
        Collavre::Comments::ApprovalGateDecision.new(comment, @user).call(decision, reason: "  Human reason  ")
      end
      assert_equal decision == "denied", comment.reload.approval_gate_denied?
      assert_equal "Human reason", comment.approval_gate_reason
      @task.reload
      assert @client.send(:restore_approval_gate)
      result = @chat.messages.last
      assert_equal :tool, result.role
      assert_equal @call.id, result.tool_call_id
      assert_equal({ "decision" => decision, "reason" => "Human reason", "decided_by" => @user.id }, JSON.parse(result.content))
      assert_equal 3, @chat.messages.size
      assert_no_enqueued_jobs do
        assert_raises(Collavre::Comments::ApprovalGateDecision::InvalidDecision) do
          Collavre::Comments::ApprovalGateDecision.new(comment, @user).call(decision)
        end
      end
    end
  end

  test "resumed job retains its snapshot during execution and clears it on completion" do
    comment = pause
    Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("approved")
    executed = false
    service = Object.new
    service.define_singleton_method(:call) do
      executed = true
    end
    factory = lambda do |task|
      assert task.running?
      assert task.pending_tool_call["messages"].present?
      @task.reload
      assert @client.send(:restore_approval_gate)
      service
    end
    Collavre::AiAgentService.stub(:new, factory) do
      Collavre::ApprovalGateResumeJob.new.perform(@task.id, @call.id)
    end
    assert executed
    assert @task.reload.done?
    assert_nil @task.pending_tool_call
  end

  test "resumption claims once and ignores stale or cancelled jobs" do
    comment = pause
    Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("approved")
    calls = []
    Collavre::AiAgentJob.stub(:perform_now, ->(task) { calls << task.id if Collavre::Workflow::TaskAdmission.start!(task) }) do
      job = Collavre::ApprovalGateResumeJob.new
      job.perform(@task.id, "stale")
      job.perform(@task.id, @call.id)
      job.perform(@task.id, @call.id)
      job.perform(-1, @call.id)
    end
    assert_equal [ @task.id ], calls
  end

  test "wrong approver and cancelled or superseded tasks cannot be decided" do
    comment = pause
    assert_raises(Collavre::Comments::ApprovalGateDecision::InvalidDecision) do
      Collavre::Comments::ApprovalGateDecision.new(comment, @agent).call("approved")
    end
    @task.update!(pending_tool_call: @task.pending_tool_call.merge("tool_call_id" => "new"))
    assert_raises(Collavre::Comments::ApprovalGateDecision::InvalidDecision) do
      Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("approved")
    end
    @task.update!(status: "cancelled")
    assert_raises(Collavre::Comments::ApprovalGateDecision::InvalidDecision) do
      Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("denied")
    end
    assert_nil comment.reload.action_executed_at
    assert_no_enqueued_jobs(only: Collavre::AiAgentJob) { Collavre::ApprovalGateResumeJob.new.perform(@task.id, @call.id) }
  end

  test "approver validation rejects blank questions missing users and AI approvers" do
    service = Collavre::Tools::ApprovalRequestService
    assert_equal @user, service.approver!(@task, "Proceed?", @user.id)
    [ [ "", nil ], [ "Proceed?", -1 ] ].each do |question, id|
      assert_raises(ArgumentError) { service.approver!(@task, question, id) }
    end
    @user.stub(:ai_user?, true) do
      Collavre::User.stub(:find_by, @user) do
        assert_raises(ArgumentError) { service.approver!(@task, "Proceed?", @user.id) }
      end
    end
    assert_raises(ArgumentError) { service.approver!(nil, "Proceed?", @user.id) }
    assert service.new.call(question: "Proceed?")[:error]
  end

  %w[approval_request meta_tool].each do |tool_name|
    { blank_question: [ "", nil, "question_required" ],
      missing_user: [ "Proceed?", -1, "invalid_approver" ],
      ai_user: [ "Proceed?", :ai_bot, "invalid_approver" ],
      inaccessible_user: [ "Proceed?", :two, "invalid_approver" ] }.each do |label, (question, user, error_key)|
      test "#{tool_name} chat returns #{label} as a tool error and accepts a corrected call" do
        approver_id = user.is_a?(Symbol) ? users(user).id : user
        @client.instance_variable_set(:@llm_api_key, "test")
        chat = @client.send(:build_conversation, [ tool_name ])
        rounds = 0
        completion = lambda do |&block|
          rounds += 1
          if rounds == 2
            result = chat.messages.last
            assert_equal :tool, result.role
            assert_equal "invalid-gate", result.tool_call_id
            assert_includes result.content, I18n.t("collavre.approval_gate.#{error_key}")
            assert @task.reload.running?
            assert_nil @task.pending_tool_call
          end
          args = rounds == 1 ? { "question" => question, "approver_user_id" => approver_id } : { "question" => "Proceed?" }
          args = { "action" => "run", "tool_name" => "approval_request", "arguments" => args } if tool_name == "meta_tool"
          id = rounds == 1 ? "invalid-gate" : "corrected-gate"
          call = RubyLLM::ToolCall.new(id: id, name: tool_name, arguments: args)
          RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { id => call })
        end
        Current.set(user: @agent, agent_turn: { task: @task }) do
          chat.stub(:provider_completion, completion) do
            @client.stub(:build_conversation, chat) do
              error = assert_raises(Collavre::ApprovalGatePendingError) do
                @client.chat([ { role: "user", content: "Ask for approval" } ], tools: [ tool_name ])
              end
              assert_equal "corrected-gate", error.tool_call_id
              assert_equal @user, error.approver
              assert_equal 2, rounds
            end
          end
        end
      end
    end
  end

  test "valid request without native interception still cannot suspend" do
    Current.set(agent_turn: { task: @task }) do
      result = Collavre::Tools::ApprovalRequestService.new.call(question: "Proceed?")
      assert_equal I18n.t("collavre.approval_gate.native_required"), result[:error]
    end
  end

  test "snapshot retains completed results and marks remaining batch calls unexecuted" do
    previous = RubyLLM::ToolCall.new(id: "previous", name: "write", arguments: {})
    later = RubyLLM::ToolCall.new(id: "later", name: "write", arguments: {})
    @chat.reset_messages!
    @chat.add_message(role: :assistant, content: "Plan", thinking: RubyLLM::Thinking.new(text: "Thought", signature: "signature"),
      tool_calls: { previous.id => previous, @call.id => @call, later.id => later })
    @chat.add_message(role: :tool, tool_call_id: previous.id, content: "Already done")
    comment = pause
    Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("denied")
    @task.reload
    assert @client.send(:restore_approval_gate)
    assert_equal "signature", @chat.messages.first.thinking.signature
    assert_equal "Already done", @chat.messages[1].content
    assert_equal [ "previous", "gate-1", "later" ], @chat.messages.filter_map(&:tool_call_id)
    assert_match "Not executed", @chat.messages.last.content
  end

  test "pending decision and cancellation cannot silently resume" do
    pause
    assert_raises(Collavre::CancelledError) { @client.send(:restore_approval_gate) }
    @task.update!(status: "cancelled")
    assert_nil @client.send(:check_tool_approval!, @call)
  end

  test "explicit approver must have access and can differ from the trigger author" do
    other = users(:two)
    @creative.stub(:has_permission?, false) do
      @task.stub(:creative, @creative) do
        assert_raises(ArgumentError) { Collavre::Tools::ApprovalRequestService.approver!(@task, "Proceed?", other.id) }
      end
    end
    Collavre::CreativeSharesCache.find_or_initialize_by(creative: @creative, user: other).update!(permission: :read)
    call = RubyLLM::ToolCall.new(id: "explicit", name: "approval_request",
      arguments: { "question" => "Proceed?", "approver_user_id" => other.id })
    comment = pause(call)
    assert_equal other, comment.approver
    Collavre::Comments::ApprovalGateDecision.new(comment, other).call("approved")
    assert_equal other.id, @task.reload.pending_tool_call.dig("decision", "decided_by")
  end

  test "pause rolls back when comment creation fails and cannot overwrite cancellation" do
    error = assert_raises(Collavre::ApprovalGatePendingError) { @client.send(:check_tool_approval!, @call) }
    handler = Collavre::AiAgent::ApprovalGateHandler.new(task: @task, agent: @agent,
      context: @task.trigger_event_payload, creative: @creative)
    Collavre::Comment.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid }) do
      assert_raises(ActiveRecord::RecordInvalid) { handler.handle(error) }
    end
    assert @task.reload.running?
    assert_nil @task.pending_tool_call
    assert_empty @task.task_actions
    @task.update!(status: "cancelled")
    assert_raises(Collavre::CancelledError) { handler.handle(error) }
  end

  test "malformed and non-gate actions are not approval gates" do
    comment = Collavre::Comment.new(action: "{invalid")
    refute comment.approval_gate?
    comment.action = "[]"
    refute comment.approval_gate?
    assert_raises(Collavre::Comments::ApprovalGateDecision::InvalidDecision) do
      Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("approved")
    end
  end

  test "retry after interrupted resume remains runnable until atomic task admission" do
    comment = pause
    Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("approved")
    Collavre::AiAgentJob.stub(:perform_now, ->(*) { raise "worker interrupted" }) do
      assert_raises(RuntimeError) { Collavre::ApprovalGateResumeJob.new.perform(@task.id, @call.id) }
    end
    assert @task.reload.pending_approval?
    assert Collavre::Workflow::TaskAdmission.start!(@task)
    refute Collavre::Workflow::TaskAdmission.start!(@task)
  end

  test "chat restores the original tool result before contacting the provider" do
    comment = pause
    Collavre::Comments::ApprovalGateDecision.new(comment, @user).call("approved")
    @task.reload
    @chat.define_singleton_method(:complete) do |&block|
      raise "missing original result" unless messages.last.tool_call_id == "gate-1"
      block.call(OpenStruct.new(content: "Resumed"))
      OpenStruct.new(content: "Resumed", input_tokens: 1, output_tokens: 1)
    end
    @client.stub(:build_conversation, @chat) do
      assert_equal "Resumed", @client.chat([ { role: "user", content: "Should not replace original history" } ])
    end
    assert_equal "Make a plan", @chat.messages.first.content
    assert_equal 3, @chat.messages.size
  end

  test "agent service uses the gate handler without generating an approval summary" do
    @task.update!(agent: users(:ai_bot))
    error = assert_raises(Collavre::ApprovalGatePendingError) { @client.send(:check_tool_approval!, @call) }
    client = Object.new
    client.define_singleton_method(:chat) { |*| raise error }
    client.define_singleton_method(:handed_off?) { true }
    client.define_singleton_method(:ask_followup) { |*| flunk "Gate questions do not need an LLM summary" }
    Collavre::AiClient.stub(:new, client) do
      assert_raises(Collavre::ApprovalGatePendingError) { Collavre::AiAgentService.new(@task).call }
    end
    assert @task.reload.pending_approval?
    assert @creative.comments.order(:id).last.approval_gate?
  end

  test "snapshot round trips image input" do
    content = RubyLLM::Content.new("Image", [ Rails.root.join("engines/collavre/test/fixtures/files/small.png") ])
    @chat.add_message(role: :user, content: content)
    dumped = Collavre::AiAgent::ApprovalConversation.dump(@chat.messages)
    Collavre::AiAgent::ApprovalConversation.restore(@chat, {
      "messages" => dumped, "tool_call_id" => @call.id, "decision" => { "decision" => "approved" }
    })
    restored = @chat.messages[2].content
    assert_equal "Image", restored.text
    assert_equal content.attachments.first.encoded, restored.attachments.first.encoded
  end
end
