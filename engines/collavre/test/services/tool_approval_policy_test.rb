# frozen_string_literal: true

require "test_helper"

class ToolApprovalPolicyTest < ActiveSupport::TestCase
  setup do
    @agent = users(:ai_bot)
  end

  test "dynamic tools flagged for approval require it" do
    McpTool.create!(creative: Creative.create!(user: users(:one), description: "Tools"), name: "gated_tool",
                    source_code: "x", approved_at: Time.current, requires_approval: true)

    assert Collavre::ToolApprovalPolicy.required?("gated_tool")
  end

  test "system tools require it only when they declare it" do
    refute Collavre::ToolApprovalPolicy.required?("creative_batch_service")
    refute Collavre::ToolApprovalPolicy.required?("creative_retrieval_service")

    Collavre::Tools::CreativeBatchService.stub(:requires_approval?, true) do
      assert Collavre::ToolApprovalPolicy.required?("creative_batch_service")
    end
  end

  test "an agent's approval list applies to that agent only" do
    @agent.update!(agent_conf: { "approval" => { "tools" => [ "creative_update_service" ] } }.to_yaml)

    assert Collavre::ToolApprovalPolicy.required?("creative_update_service", agent: @agent)
    refute Collavre::ToolApprovalPolicy.required?("creative_update_service", agent: users(:one))
    refute Collavre::ToolApprovalPolicy.required?("creative_update_service")
    refute Collavre::ToolApprovalPolicy.agent_requires_approval?(nil, "creative_update_service")
  end
end
