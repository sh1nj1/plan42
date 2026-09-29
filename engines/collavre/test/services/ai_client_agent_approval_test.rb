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

  test "an approved pending call proceeds" do
    @agent.update!(agent_conf: { "approval" => { "tools" => [ "creative_update_service" ] } }.to_yaml)
    @task.update!(pending_tool_call: { "tool_name" => "creative_update_service", "approved" => true })

    assert_nil check
    assert_nil @task.reload.pending_tool_call
  end
end
