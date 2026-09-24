require "test_helper"

class AgentModelsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @owner = users(:two)
    @agent = users(:ai_bot)
    @agent.update!(created_by_id: @owner.id)
    sign_in_as @owner, password: "password"
  end

  test "owner can read and update the agent default without changing other settings" do
    get user_agent_model_path(@agent)
    assert_response :success
    assert_select "input[name='user[llm_model]'][value=?]", @agent.llm_model
    assert_includes response.headers["Cache-Control"], "no-store"
    vendor = @agent.llm_vendor
    patch user_agent_model_path(@agent), params: { user: { llm_model: " custom-model ", llm_vendor: "changed", name: "changed" } }
    assert_response :success
    assert_equal "custom-model", @agent.reload.llm_model
    assert_equal vendor, @agent.llm_vendor
    assert_not_equal "changed", @agent.name
    assert Collavre::LlmModel.exists?(llm_vendor: vendor, name: "custom-model")
  end

  test "suggestion failure rolls back the model and does not enqueue a fast sync" do
    gateway = Collavre::AgentGateway.create!(
      owner: @owner, name: "Atomic model gateway", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    @agent.update!(llm_vendor: "cli_proxy", agent_gateway: gateway,
                   llm_model: "paperclip/claude_local", codex_fast_mode: true)
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    failed_write = lambda do |vendor:, name:, creator:|
      Collavre::LlmModel.create!(llm_vendor: vendor, name: name, creator: creator)
      raise ActiveRecord::StatementInvalid, "Simulated suggestion failure"
    end

    assert_no_enqueued_jobs(only: Collavre::AgentProvisioningSyncJob) do
      Collavre::LlmModel.stub :remember!, failed_write do
        assert_raises(ActiveRecord::StatementInvalid) do
          patch user_agent_model_path(@agent), params: { user: { llm_model: "paperclip/codex_local" } }
        end
      end
    end
    assert_equal "paperclip/claude_local", @agent.reload.llm_model
    assert_not Collavre::LlmModel.exists?(llm_vendor: "cli_proxy", name: "paperclip/codex_local")
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter if previous_adapter
  end

  test "admin may change another owner's agent" do
    sign_in_as users(:one), password: "password"
    patch user_agent_model_path(@agent), params: { user: { llm_model: "admin-model" } }
    assert_response :success
    assert_equal "admin-model", @agent.reload.llm_model
  end

  test "other users cannot read or update the editor" do
    @agent.update!(created_by_id: users(:one).id)
    old_model = @agent.llm_model
    get user_agent_model_path(@agent)
    assert_response :forbidden
    patch user_agent_model_path(@agent), params: { user: { llm_model: "unauthorized" } }
    assert_response :forbidden
    assert_equal old_model, @agent.reload.llm_model
  end

  test "human profiles and signed-out requests cannot change models" do
    patch user_agent_model_path(@owner), params: { user: { llm_model: "not-an-agent" } }
    assert_response :forbidden
    sign_out
    patch user_agent_model_path(@agent), params: { user: { llm_model: "anonymous" } }
    assert_response :redirect
  end

  test "blank and oversized models do not replace the saved default" do
    old_model = @agent.llm_model
    [ " ", "x" * 256 ].each do |model|
      patch user_agent_model_path(@agent), params: { user: { llm_model: model } }
      assert_response :unprocessable_entity
      assert_equal old_model, @agent.reload.llm_model
      assert_select "[role='status']", text: /invalid/
    end
  end
end
