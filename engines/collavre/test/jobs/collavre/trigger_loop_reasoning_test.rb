# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Collavre
  class TriggerLoopReasoningTest < ActiveSupport::TestCase
    setup do
      WebMock.disable_net_connect!
      owner = users(:one)
      gateway = AgentGateway.create!(owner: owner, name: "Verifier proxy", base_url: "https://proxy.example.com",
                                     admin_key: "admin", completion_key: "completion")
      @verifier = User.create!(name: "Verifier", email: "verifier@ai.local", password: SecureRandom.hex(24),
                               system_prompt: "Verify", llm_vendor: "cli_proxy", llm_model: "paperclip/claude_local",
                               reasoning_effort: "high", created_by_id: owner.id, agent_gateway: gateway)
      @task = Task.new(agent: @verifier, creative: creatives(:tshirt))
    end

    teardown do
      WebMock.allow_net_connect!
    end

    test "status evaluation sends the verifier default through the real client" do
      CreativeShare.create!(creative: creatives(:tshirt), user: @verifier, permission: :read)
      request = stub_verifier_response("BLOCKED")
      job = TriggerLoopCheckJob.new
      job.stub(:pick_fallback_agent, @verifier) do
        job.stub(:collect_fallback_instructions, "Complete the task") do
          result = job.send(:llm_fallback_evaluate, creatives(:tshirt), creatives(:tshirt),
                            Struct.new(:content).new("Cannot continue"), @task)
          assert_equal :awaiting_user, result
        end
      end
      assert_requested request
    end

    test "completion verification sends the verifier default through the real client" do
      request = stub_verifier_response("AWAITING_USER")
      result = TriggerLoopVerifyJob.new.send(:verify_completion, @verifier, "Ask for approval", "Waiting", @task)
      assert_equal :awaiting_user, result
      assert_requested request
    end

    private

    def stub_verifier_response(content)
      verdict = { answers: { status: { choice: content } }, reason: "Waiting for approval" }.to_json
      data = { choices: [ { index: 0, message: { role: "assistant", content: verdict } } ] }
      stub_request(:post, "https://proxy.example.com/v1/chat/completions")
        .with do |request|
          body = JSON.parse(request.body)
          body["reasoning_effort"] == "high" && body["x_cli_events"] == "reasoning" &&
            body["model"] == @verifier.llm_model
        end
        .to_return(status: 200, body: data.to_json,
                   headers: { "Content-Type" => "application/json" })
    end
  end
end
