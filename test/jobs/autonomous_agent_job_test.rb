require "test_helper"

class AutonomousAgentJobTest < ActiveJob::TestCase
  setup do
    @user = users(:one)
    @ai_user = users(:ai_bot)
    @creative = creatives(:tshirt)
    @agent_run = AgentRun.create!(
      creative: @creative,
      ai_user: @ai_user,
      goal: "Test Goal",
      status: "pending"
    )
  end

  test "performs agent run" do
    # Mock AgentClient
    mock_client = Minitest::Mock.new
    mock_client.expect :chat, "AI Response" do |messages, **kwargs|
      messages.is_a?(Array)
    end

    AgentClient.stub :new, mock_client do
      AutonomousAgentJob.perform_now(@agent_run.id)
    end

    @agent_run.reload
    assert_equal "success", @agent_run.status
    assert_equal "completed", @agent_run.state
    assert_equal 1, @agent_run.transcript.length
    assert_equal "model", @agent_run.transcript.last["role"]
    assert_equal "AI Response", @agent_run.transcript.last["parts"].first["text"]

    mock_client.verify
  end

  test "handles errors" do
    AgentClient.stub :new, ->(*args) { raise "API Error" } do
      assert_raises(RuntimeError) do
        AutonomousAgentJob.perform_now(@agent_run.id)
      end
    end

    @agent_run.reload
    assert_equal "error", @agent_run.status
    assert_equal "API Error", @agent_run.context["error"]
  end
end
