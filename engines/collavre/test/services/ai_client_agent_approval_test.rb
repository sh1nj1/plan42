# frozen_string_literal: true

require "test_helper"

# agent_conf `approval: { tools: [...] }` gates tools for one agent only.
class AiClientAgentApprovalTest < ActiveSupport::TestCase
  setup do
    @agent = users(:ai_bot)
    @creative = creatives(:tshirt)
    @task = Collavre::Task.create!(name: "Approval", status: "running", agent: @agent,
      creative: @creative, topic_id: @creative.main_topic.id, trigger_event_name: "comment_created")
    @client = Collavre::AiClient.new(vendor: "openai", model: "gpt-4.1", system_prompt: nil,
                                     context: { task: @task }, log_interactions: false)
    @call = RubyLLM::ToolCall.new(id: "c-1", name: "creative_update_service", arguments: {})
  end

  def check
    @client.send(:check_tool_approval!, @call)
  end

  test "tools listed in the agent's approval config wait for approval" do
    @agent.update!(agent_conf: { "approval" => { "tools" => [ "creative_update_service" ] } }.to_yaml)

    error = assert_raises(Collavre::ApprovalPendingError) { check }
    assert_equal @task, error.task
  end

  test "other tools and agents without the config run directly" do
    assert_nil check

    @agent.update!(agent_conf: { "approval" => { "tools" => [ "topic_create" ] } }.to_yaml)
    assert_nil check
  end

  test "completed approval never authorizes a newly generated call" do
    require_approval
    @task.update!(pending_tool_call: { "tool_name" => @call.name, "tool_call_id" => @call.id,
      "arguments" => {}, "approved" => true, "result" => { "id" => 42 } })

    [ @call, RubyLLM::ToolCall.new(id: "c-2", name: @call.name, arguments: {}),
      RubyLLM::ToolCall.new(id: @call.id, name: @call.name, arguments: { "description" => "changed" }) ].each do |call|
      assert_raises(Collavre::ApprovalPendingError) { @client.send(:check_tool_approval!, call) }
    end
    assert @task.reload.pending_tool_call["approved"]
  end

  test "approval preserves the interrupted conversation and restores the executed result exactly once" do
    require_approval
    chat = conversation
    earlier = RubyLLM::ToolCall.new(id: "earlier", name: "read", arguments: {})
    skipped = RubyLLM::ToolCall.new(id: "skipped", name: @call.name, arguments: {})
    chat.add_message(role: :assistant, content: nil, tool_calls: { earlier.id => earlier })
    chat.add_message(role: :tool, tool_call_id: earlier.id, content: "prior result")
    chat.add_message(role: :assistant, content: nil, tool_calls: { @call.id => @call, skipped.id => skipped })
    @client.instance_variable_set(:@conversation, chat)
    error = assert_raises(Collavre::ApprovalPendingError) { check }
    Collavre::AiAgent::ApprovalHandler.new(task: @task, agent: @agent,
      context: {}, creative: @creative).handle(error)
    comment = @creative.comments.order(:id).last
    snapshot = @task.reload.pending_tool_call["messages"]
    assert_equal 4, snapshot.size

    executions = 0
    service = Object.new
    service.define_singleton_method(:call) do |**args|
      executions += 1
      { created_id: 42 }
    end
    ::Tools::MetaToolService.stub(:new, -> { service }) do
      Collavre::AiAgentJob.stub(:perform_later, nil) do
        Collavre::Comments::ActionExecutor.new(comment: comment, executor: comment.approver).call
      end
    end
    assert_equal snapshot, @task.reload.pending_tool_call["messages"]

    restored = conversation
    @client.instance_variable_set(:@conversation, restored)
    2.times do
      @client.stub(:build_conversation, restored) do
        @client.send(:prepare_gate_conversation, [ { role: "user", text: "Newly rebuilt history" } ], [])
      end
      refute_includes restored.messages.map(&:content), "Newly rebuilt history"
      results = restored.messages.select { |message| message.role == :tool }
      assert_equal 3, results.size
      assert_equal "prior result", results.find { |message| message.tool_call_id == earlier.id }.content
      assert_equal({ "created_id" => 42 }, JSON.parse(results.find { |message| message.tool_call_id == @call.id }.content))
      assert JSON.parse(results.find { |message| message.tool_call_id == skipped.id }.content).key?("error")
    end
    assert_equal 1, executions
    assert_raises(Collavre::ApprovalPendingError) { check }
  end

  test "legacy approvals restore their result and unapproved calls are not restored" do
    @client.instance_variable_set(:@conversation, conversation)
    assert_not @client.send(:restore_tool_approval, [])
    @task.update!(pending_tool_call: { "tool_name" => @call.name, "tool_call_id" => @call.id,
      "arguments" => {}, "approved" => true, "result" => { "error" => "failed" } })
    assert @client.send(:restore_tool_approval, [])
    result = @client.instance_variable_get(:@conversation).messages.last
    assert_equal @call.id, result.tool_call_id
    assert_equal({ "error" => "failed" }, JSON.parse(result.content))
  end

  private

  def require_approval
    @agent.update!(agent_conf: { "approval" => { "tools" => [ @call.name ] } }.to_yaml)
  end

  def conversation
    RubyLLM.context { |config| config.openai_api_key = "test" }
      .chat(model: "gpt-4.1", provider: :openai, assume_model_exists: true).tap do |chat|
      chat.add_message(role: :user, content: "Update the creative")
    end
  end
end
