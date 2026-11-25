require "test_helper"

class AgentModelsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @owner = users(:two)
    @agent = users(:ai_bot)
    @agent.update!(created_by_id: @owner.id)
    sign_in_as @owner, password: "password"
  end

  test "CLI avatar reads and saves agent thinking independently of message options" do
    gateway = Collavre::AgentGateway.create!(
      owner: @owner, name: "Thinking avatar", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    @agent.update!(llm_vendor: "cli_proxy", agent_gateway: gateway,
                   llm_model: "paperclip/codex_local", reasoning_effort: "high")
    %i[en ko].each do |locale|
      @owner.update!(locale: locale)
      get user_agent_model_path(@agent)
      assert_response :success
      assert_select "select[name='user[reasoning_effort]'] option[selected][value='high']"
      assert_select "[data-thinking-toggle]", count: 0
      assert_select "select[name='user[reasoning_effort]'] option[value='max']", count: 0
      select = css_select("select[name='user[reasoning_effort]']").first
      assert_equal Collavre::CliProxy::RunOptions::EFFORTS.stringify_keys, JSON.parse(select["data-efforts"])
      assert_select "form[data-action*='change->comment-agent-model#modelChanged']"
      assert_equal "high", @agent.reload.reasoning_effort
    end
    patch user_agent_model_path(@agent), params: { user: { llm_model: @agent.llm_model, reasoning_effort: "low" },
                                                  comment: { agent_run_options: { reasoning_effort: "xhigh" } } }
    assert_response :success
    assert_equal "low", @agent.reload.reasoning_effort
    patch user_agent_model_path(@agent), params: { user: { llm_model: @agent.llm_model, reasoning_effort: "max" } }
    assert_response :unprocessable_entity
    assert_equal "low", @agent.reload.reasoning_effort
    patch user_agent_model_path(@agent), params: { user: { llm_model: @agent.llm_model, reasoning_effort: "" } }
    assert_response :success
    assert_nil @agent.reload.reasoning_effort
  end

  test "owner can read and update the agent default without changing other settings" do
    get user_agent_model_path(@agent)
    assert_response :success
    assert_select "input[name='user[llm_model]'][value=?]", @agent.llm_model
    assert_includes response.headers["Cache-Control"], "no-store"
    vendor = @agent.llm_vendor
    patch user_agent_model_path(@agent), params: { user: { llm_model: " custom-model ", llm_vendor: "changed", name: "changed", reasoning_effort: "high" } }
    assert_response :success
    assert_equal "custom-model", @agent.reload.llm_model
    assert_equal vendor, @agent.llm_vendor
    assert_nil @agent.reasoning_effort
    assert_not_equal "changed", @agent.name
    assert Collavre::LlmModel.exists?(llm_vendor: vendor, name: "custom-model")
  end

  test "avatar uses the shared searchable model picker with vendor history and unique ids" do
    remembered = Collavre::LlmModel.remember!(vendor: @agent.llm_vendor, name: "previous-model", creator: @owner)
    Collavre::LlmModel.remember!(vendor: "other-vendor", name: "unrelated-model", creator: @owner)
    ids = 2.times.map do
      get user_agent_model_path(@agent)
      assert_response :success
      picker = css_select("[data-controller='llm-model']").first
      models = JSON.parse(picker["data-llm-model-models-value"])
      assert_includes models.map { |model| model["name"] }, remembered.name
      assert_not_includes models.map { |model| model["name"] }, "unrelated-model"
      assert_equal llm_model_path(remembered), models.find { |model| model["id"] == remembered.id }["delete_url"]
      menu_id = picker["data-llm-model-menu-id-value"]
      assert_select "##{menu_id} .common-popup-list"
      assert_select "input[data-llm-model-target='vendor'][value=?]", @agent.llm_vendor
      assert_select "input[name='user[llm_model]'][data-llm-model-target='input']"
      assert_select "datalist", count: 0
      menu_id
    end
    assert_not_equal(*ids)

    patch user_agent_model_path(@agent), params: { user: { llm_model: "newly-entered-model" } }
    assert_response :success
    picker = css_select("[data-controller='llm-model']").first
    assert_includes JSON.parse(picker["data-llm-model-models-value"]).map { |model| model["name"] }, "newly-entered-model"
  end

  test "suggestion failure rolls back the model and does not enqueue a fast sync" do
    gateway = Collavre::AgentGateway.create!(
      owner: @owner, name: "Atomic model gateway", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    @agent.update!(llm_vendor: "cli_proxy", agent_gateway: gateway,
                   llm_model: "paperclip/claude_local", reasoning_effort: "max", codex_fast_mode: true)
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
    assert_equal "max", @agent.reasoning_effort
    assert_not Collavre::LlmModel.exists?(llm_vendor: "cli_proxy", name: "paperclip/codex_local")
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter if previous_adapter
  end

  test "model changes clear incompatible efforts and preserve compatible defaults" do
    gateway = Collavre::AgentGateway.create!(
      owner: @owner, name: "Effort gateway", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    @agent.update!(llm_vendor: "cli_proxy", agent_gateway: gateway)
    [
      [ "codex_local", "minimal", "claude_local", nil ],
      [ "claude_local", "max", "codex_local", nil ],
      [ "codex_local", "high", "claude_local", "high" ],
      [ "claude_local", nil, "codex_local", nil ]
    ].each do |original, effort, target, expected|
      @agent.update!(llm_model: "paperclip/#{original}", reasoning_effort: effort)
      patch user_agent_model_path(@agent), params: { user: { llm_model: "paperclip/#{target}" } }
      assert_response :success
      assert_equal "paperclip/#{target}", @agent.reload.llm_model
      expected ? assert_equal(expected, @agent.reasoning_effort) : assert_nil(@agent.reasoning_effort)
    end
  end

  test "model changes clear resubmitted incompatible defaults but reject changed incompatible efforts" do
    gateway = Collavre::AgentGateway.create!(
      owner: @owner, name: "Resubmitted effort", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion"
    )
    @agent.update!(llm_vendor: "cli_proxy", agent_gateway: gateway)
    [
      [ "codex_local", "minimal", "claude_local", nil ],
      [ "claude_local", "max", "codex_local", nil ],
      [ "codex_local", "high", "claude_local", "high" ]
    ].each do |original, effort, target, expected|
      @agent.update!(llm_model: "paperclip/#{original}", reasoning_effort: effort)
      patch user_agent_model_path(@agent), params: {
        user: { llm_model: "paperclip/#{target}", reasoning_effort: " #{effort} " }
      }
      assert_response :success
      assert_equal "paperclip/#{target}", @agent.reload.llm_model
      expected ? assert_equal(expected, @agent.reasoning_effort) : assert_nil(@agent.reasoning_effort)
    end

    @agent.update!(llm_model: "paperclip/codex_local", reasoning_effort: "low")
    patch user_agent_model_path(@agent), params: {
      user: { llm_model: "paperclip/claude_local", reasoning_effort: "minimal" }
    }
    assert_response :unprocessable_entity
    assert_equal "paperclip/codex_local", @agent.reload.llm_model
    assert_equal "low", @agent.reasoning_effort
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
    patch user_agent_model_path(@agent), params: { user: { llm_model: "unauthorized", reasoning_effort: "high" } }
    assert_response :forbidden
    assert_equal old_model, @agent.reload.llm_model
    assert_nil @agent.reasoning_effort
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
