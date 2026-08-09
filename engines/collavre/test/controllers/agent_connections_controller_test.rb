require "test_helper"

class AgentConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:two)
    @other = users(:three)
    @gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Connection proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "c" * 32,
      workspace_mode: :per_user
    )
    @agent = Collavre::User.create!(
      name: "Connection Agent",
      email: "connection-agent@ai.local",
      password: SecureRandom.hex(24),
      system_prompt: "Help",
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/codex_local",
      created_by_id: @owner.id,
      agent_gateway: @gateway
    )
    Collavre::Contact.ensure(user: @other, contact_user: @agent)
  end

  test "per-user agent lets each contact create only their workspace" do
    sign_in_as(@other, password: "password")
    get collavre.agent_connection_user_path(@agent)

    assert_response :success
    workspace = Collavre::AgentWorkspace.find_by!(agent: @agent, user: @other)
    assert_includes response.body, workspace.proxy_user_id
    assert_equal "agent-#{@agent.id}--user-#{@other.id}", workspace.proxy_user_id
  end

  test "shared mode only lets the agent owner manage login" do
    @gateway.update!(workspace_mode: :shared)
    sign_in_as(@other, password: "password")
    get collavre.agent_connection_user_path(@agent)
    assert_response :forbidden
  end

  test "inactive gateway returns unavailable before creating a workspace" do
    @gateway.update!(active: false)
    sign_in_as(@owner, password: "password")

    assert_no_difference("Collavre::AgentWorkspace.count") do
      get collavre.agent_connection_user_path(@agent)
    end

    assert_response :service_unavailable
  end

  test "connection page provides localized proxy status labels" do
    @owner.update!(locale: "ko")
    sign_in_as(@owner, password: "password")

    get collavre.agent_connection_user_path(@agent)

    assert_response :success
    labels = JSON.parse(css_select("[data-agent-connection-status-labels-value]").sole[
      "data-agent-connection-status-labels-value"
    ])
    assert_equal "인증됨", labels.fetch("authenticated")
    assert_equal "승인 대기", labels.fetch("pending_approval")
    assert_equal "설치됨", labels.fetch("installed")

    item_types = JSON.parse(css_select("[data-agent-connection-item-type-labels-value]").sole[
      "data-agent-connection-item-type-labels-value"
    ])
    assert_equal "스킬", item_types.fetch("skill")
    assert_equal "설정", item_types.fetch("config")
  end

  test "authentication submission uses a filtered secret parameter" do
    credential = "provider-secret-that-must-not-be-logged"
    received = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:submit_auth_session) do |engine, session_id, auth_secret|
      received = [ engine, session_id, auth_secret ]
      { "status" => "authorized" }
    end
    sign_in_as(@owner, password: "password")

    Collavre::CliProxy::Client.stub(:new, fake_client) do
      post collavre.agent_connection_auth_session_path(
        user_id: @agent.id,
        engine: "codex",
        session_id: "session-1"
      ), params: { auth_secret: credential }, as: :json
    end

    assert_response :success
    assert_equal [ "codex", "session-1", credential ], received
    assert_equal "[FILTERED]", request.filtered_parameters.fetch("auth_secret")
    refute_includes request.filtered_parameters.inspect, credential
  end
end
