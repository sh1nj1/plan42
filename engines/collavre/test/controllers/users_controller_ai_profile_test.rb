require "test_helper"

class UsersControllerAiProfileTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = users(:two)
    @agent = users(:ai_bot)
    @agent.update!(created_by_id: users(:one).id, searchable: true,
                   llm_api_key: "profile-secret-key", gateway_url: "https://private-gateway.example",
                   agent_conf: "private_config: private-value")
    sign_in_as @viewer, password: "password"
  end

  test "non-owner sees existing form read-only without infrastructure configuration" do
    get edit_ai_user_url(@agent)

    assert_response :success
    assert_select "fieldset[disabled] input[name='user[name]'][value=?]", @agent.name
    assert_select "fieldset[disabled] textarea[name='user[system_prompt]']", @agent.system_prompt
    assert_select "button[type='submit'][disabled]"
    assert_select "form[data-controller='agent-vendor']", count: 0
    %w[llm_vendor llm_model llm_api_key clear_llm_api_key gateway_url agent_gateway_id agent_conf reasoning_effort codex_fast_mode].each do |field|
      assert_select "[name='user[#{field}]']", count: 0
    end
    [ @agent.llm_model, "profile-secret-key", "private-gateway.example", "private-value" ].each do |secret|
      assert_not_includes response.body, secret
    end
    assert_select "a[href=?]", agent_connection_user_path(@agent), count: 0
  end

  test "read-only notice is translated in both supported languages" do
    { en: "Only the owner or a system administrator can edit this agent.",
      ko: "소유자 또는 시스템 관리자만 이 에이전트를 수정할 수 있습니다." }.each do |locale, notice|
      @viewer.update!(locale: locale)
      get edit_ai_user_url(@agent)
      assert_response :success
      assert_includes response.body, notice
    end
  end

  test "read-only tools show only selected tools visible to the viewer" do
    @agent.update!(tools: %w[visible_tool hidden_tool])
    tools = [ { name: "visible_tool", description: "Visible capability", params: {} },
              { name: "unused_tool", description: "Unused capability", params: {} } ]
    Collavre::McpService.stub(:available_tools, tools) do
      get edit_ai_user_url(@agent)
    end
    assert_response :success
    assert_includes response.body, "Visible capability"
    assert_not_includes response.body, "hidden_tool"
    assert_not_includes response.body, "Unused capability"
  end

  test "AI profile opens the reused edit page" do
    get user_url(@agent)
    assert_redirected_to edit_ai_user_url(@agent)
    follow_redirect!
    assert_response :success
    assert_select "button[type='submit'][disabled]"
  end

  test "private unshared agent cannot be inspected even by guessing the id" do
    @agent.update!(searchable: false)
    get edit_ai_user_url(@agent)
    assert_response :not_found
    assert_not_includes response.body, @agent.system_prompt
  end

  test "private agent shared on a readable creative can be inspected" do
    @agent.update!(searchable: false)
    creative = Collavre::Creative.create!(user: @viewer, description: "Shared agent")
    Collavre::CreativeSharesCache.create!(creative: creative, user: @agent, permission: :feedback)

    get edit_ai_user_url(@agent)
    assert_response :success
    assert_select "button[type='submit'][disabled]"

    Collavre::CreativeSharesCache.where(creative: creative, user: @agent).update_all(permission: :no_access)
    get edit_ai_user_url(@agent)
    assert_response :not_found
  end

  test "sharing an agent on another user's private creative does not expose its profile" do
    @agent.update!(searchable: false)
    creative = Collavre::Creative.create!(user: users(:one), description: "Private workspace")
    Collavre::CreativeSharesCache.create!(creative: creative, user: @agent, permission: :feedback)
    get edit_ai_user_url(@agent)
    assert_response :not_found
  end

  test "non-owner cannot update a searchable agent through a direct request" do
    original = @agent.attributes
    patch update_ai_user_url(@agent), params: { user: { name: "Changed", system_prompt: "Changed", llm_api_key: "Changed" } }
    assert_response :redirect
    assert_equal original, @agent.reload.attributes
  end

  test "owner retains editable configuration" do
    @agent.update!(created_by_id: @viewer.id, searchable: false)
    get edit_ai_user_url(@agent)
    assert_response :success
    assert_select "fieldset[disabled]", count: 0
    assert_select "select[name='user[llm_vendor]']"
    assert_select "input[name='user[llm_api_key]']"
    assert_select "textarea[name='user[agent_conf]']"
    assert_select "button[type='submit']:not([disabled])"
    patch update_ai_user_url(@agent), params: { user: { name: "Updated by owner" } }
    assert_response :redirect
    assert_equal "Updated by owner", @agent.reload.name
  end

  test "system administrator retains existing management access" do
    sign_in_as users(:one), password: "password"
    @agent.update!(created_by_id: nil, searchable: false)
    get edit_ai_user_url(@agent)
    assert_response :success
    assert_select "button[type='submit']:not([disabled])"
  end

  test "anonymous visitors must sign in" do
    sign_out
    get edit_ai_user_url(@agent)
    assert_redirected_to new_session_url
  end
end
