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
end
