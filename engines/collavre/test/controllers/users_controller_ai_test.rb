require "test_helper"

class UsersControllerAiTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @ai_user = users(:ai_bot)
    sign_in_as @admin, password: "password"
  end

  test "should get new_ai page with tools list" do
    model = Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5")

    get new_ai_users_url
    assert_response :success
    assert_select "h1", I18n.t("collavre.users.new_ai.title")
    assert_select "form[action=?]", create_ai_users_path
    assert_select "input[name='llm_model'][maxlength=?]", Collavre::LlmModel::MAX_NAME_LENGTH.to_s
    assert_select "input[type='text'][name='llm_api_key'].masked-secret-field[autocomplete='off'][autocapitalize='none'][spellcheck='false']"
    assert_select "a[href=?][data-turbo='false']", agent_gateways_path,
                  text: I18n.t("collavre.users.new_ai.manage_gateways")
    assert_select "[data-controller='llm-model']" do |nodes|
      models = JSON.parse(nodes.first["data-llm-model-models-value"])
      assert_includes models, {
        "id" => model.id,
        "vendor" => "openai",
        "name" => "gpt-5",
        "delete_url" => llm_model_path(model)
      }
    end
    form_groups = css_select("form .form-group")
    vendor_group = form_groups.index { |group| group.at_css("select[name='llm_vendor']") }
    gateway_group = form_groups.index { |group| group.at_css("select[name='agent_gateway_id']") }
    assert_equal vendor_group + 1, gateway_group
    # Verify tools section is rendered
    assert_select "label", I18n.t("collavre.users.edit_ai.meta_skills_title")
  end

  test "should get new_ai page and display available tools" do
    # Stub the controller's load_available_tools method to return mock tools
    mock_tools = [
      { name: "test_tool", description: "A test tool", parameters: { type: "object" } }
    ]

    # Store original method
    original_method = Collavre::UsersController.instance_method(:load_available_tools)

    Collavre::UsersController.send(:define_method, :load_available_tools) { mock_tools }

    get new_ai_users_url
    assert_response :success
    # Verify tool is displayed
    assert_select ".tools-selection" do
      assert_select "strong", "test_tool"
      assert_select ".text-muted.small", "A test tool"
    end
  ensure
    # Restore original method
    Collavre::UsersController.send(:define_method, :load_available_tools, original_method)
  end

  test "should get edit_ai for ai user" do
    @ai_user.update!(llm_api_key: "existing-secret-key")

    get edit_ai_user_url(@ai_user)

    assert_response :success
    assert_select "h1", "Edit AI Agent"
    assert_select "form[action=?]", update_ai_user_path(@ai_user)
    assert_select "input[type='text'][name='user[llm_api_key]'].masked-secret-field[autocomplete='off'][autocapitalize='none'][spellcheck='false']"
    assert_select "input[type='checkbox'][name='user[clear_llm_api_key]'][value='1']"
    assert_select "label[for='user_clear_llm_api_key']", I18n.t("collavre.users.edit_ai.clear_api_key_label")
    assert_predicate css_select("input[name='user[llm_api_key]']").first["value"], :blank?
    assert_not_includes response.body, "existing-secret-key"
  end

  test "creates a CLI Proxy agent with one of the current user's gateways" do
    gateway = Collavre::AgentGateway.create!(
      owner: @admin,
      name: "Create agent proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )

    assert_difference("Collavre::User.count", 1) do
      post create_ai_users_url, params: {
        ai_id: "proxy_bot",
        name: "Proxy Bot",
        system_prompt: "Help",
        llm_vendor: "cli_proxy",
        llm_model: "paperclip/claude_local",
        agent_gateway_id: gateway.id
      }
    end

    agent = Collavre::User.find_by!(email: "proxy_bot@ai.local")
    assert_equal gateway, agent.agent_gateway
    assert_equal @admin.id, agent.created_by_id
  end

  test "does not offer or assign a provisioning-only gateway to a CLI Proxy agent" do
    gateway = Collavre::AgentGateway.create!(
      owner: @admin,
      name: "Provisioning-only proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin"
    )

    get new_ai_users_url
    assert_response :success
    assert_select "select[name='agent_gateway_id'] option[value='#{gateway.id}']", count: 0

    assert_no_difference("Collavre::User.count") do
      post create_ai_users_url, params: {
        ai_id: "keyless_proxy_bot",
        name: "Keyless Proxy Bot",
        system_prompt: "Help",
        llm_vendor: "cli_proxy",
        llm_model: "paperclip/claude_local",
        agent_gateway_id: gateway.id
      }
    end

    assert_response :unprocessable_entity
  end

  test "rejects another user's gateway for a CLI Proxy agent" do
    foreign_gateway = Collavre::AgentGateway.create!(
      owner: users(:two),
      name: "Foreign proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )

    assert_no_difference("Collavre::User.count") do
      post create_ai_users_url, params: {
        ai_id: "foreign_proxy_bot",
        name: "Foreign Proxy Bot",
        system_prompt: "Help",
        llm_vendor: "cli_proxy",
        llm_model: "paperclip/claude_local",
        agent_gateway_id: foreign_gateway.id
      }
    end

    assert_response :unprocessable_entity
  end

  test "preserves the assigned inactive gateway while editing a CLI Proxy agent" do
    gateway = Collavre::AgentGateway.create!(
      owner: @admin,
      name: "Inactive assigned proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
    @ai_user.update!(
      created_by_id: @admin.id,
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      agent_gateway: gateway
    )
    gateway.update!(active: false)

    get edit_ai_user_url(@ai_user)

    assert_response :success
    assert_select "select[name='user[agent_gateway_id]'] option[value='#{gateway.id}'][selected]", gateway.name

    patch update_ai_user_url(@ai_user), params: {
      user: {
        name: "Renamed inactive proxy agent",
        llm_vendor: "cli_proxy",
        llm_model: "paperclip/claude_local",
        agent_gateway_id: gateway.id
      }
    }

    assert_redirected_to user_path(@admin, tab: "contacts")
    assert_equal "Renamed inactive proxy agent", @ai_user.reload.name
    assert_equal gateway, @ai_user.agent_gateway
  end

  test "profile shows connection help for the gateway workspace mode in both locales" do
    gateway = Collavre::AgentGateway.create!(
      owner: @admin,
      name: "Profile help proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "i" * 32
    )
    @ai_user.update!(
      created_by_id: @admin.id,
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      agent_gateway: gateway
    )

    get user_url(@ai_user)
    assert_response :success
    assert_includes response.body, I18n.t("collavre.agent_connections.profile_help.shared", locale: :en)
    assert_not_includes response.body, I18n.t("collavre.agent_connections.profile_help.per_user", locale: :en)

    gateway.update!(workspace_mode: :per_user)
    @admin.update!(locale: "ko")
    get user_url(@ai_user)
    assert_response :success
    assert_includes response.body, I18n.t("collavre.agent_connections.profile_help.per_user", locale: :ko)
    assert_not_includes response.body, I18n.t("collavre.agent_connections.profile_help.shared", locale: :ko)
  end

  test "does not assign a different inactive gateway while editing" do
    inactive_gateway = Collavre::AgentGateway.create!(
      owner: @admin,
      name: "Inactive unassigned proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      active: false
    )

    patch update_ai_user_url(@ai_user), params: {
      user: {
        llm_vendor: "cli_proxy",
        llm_model: "paperclip/claude_local",
        agent_gateway_id: inactive_gateway.id
      }
    }

    assert_response :unprocessable_entity
    assert_nil @ai_user.reload.agent_gateway
  end

  test "should not get edit_ai for normal user" do
    get edit_ai_user_url(@admin)
    assert_redirected_to user_path(@admin)
    assert_equal "This user is not an AI agent.", flash[:alert]
  end

  test "should update ai user and redirect to contacts" do
    patch update_ai_user_url(@ai_user), params: {
      user: {
        name: "Updated Bot Name",
        system_prompt: "New prompt",
        llm_model: "gemini-1.5-pro",
        searchable: true
      }
    }
    assert_redirected_to user_path(@admin, tab: "contacts")
    @ai_user.reload
    assert_equal "Updated Bot Name", @ai_user.name
    assert_equal "New prompt", @ai_user.system_prompt
    assert_equal "gemini-1.5-pro", @ai_user.llm_model
    assert @ai_user.searchable
  end

  test "creating an ai user remembers its model" do
    assert_difference("Collavre::LlmModel.count", 1) do
      post create_ai_users_url, params: {
        ai_id: "custom-model-bot",
        name: "Custom Model Bot",
        system_prompt: "Use the configured model.",
        llm_vendor: "openai",
        llm_model: "gpt-5.2"
      }
    end

    model = Collavre::LlmModel.find_by!(llm_vendor: "openai", name: "gpt-5.2")
    assert_equal @admin, model.creator
  end

  test "failed ai user creation does not remember its model" do
    assert_no_difference("Collavre::LlmModel.count") do
      post create_ai_users_url, params: {
        ai_id: "invalid-model-bot",
        name: "",
        system_prompt: "Use the configured model.",
        llm_vendor: "openai",
        llm_model: "unsaved-model"
      }
    end

    assert_response :unprocessable_entity
    refute Collavre::LlmModel.exists?(llm_vendor: "openai", name: "unsaved-model")
  end

  test "oversized model does not partially create an ai user or suggestion" do
    oversized_model = "m" * (Collavre::LlmModel::MAX_NAME_LENGTH + 1)

    assert_no_difference([ "Collavre::User.count", "Collavre::LlmModel.count" ]) do
      post create_ai_users_url, params: {
        ai_id: "oversized-model-bot",
        name: "Oversized Model Bot",
        llm_vendor: "openai",
        llm_model: oversized_model
      }
    end

    assert_response :unprocessable_entity
    assert_select "input[name='llm_model'][maxlength=?]", Collavre::LlmModel::MAX_NAME_LENGTH.to_s
  end

  test "oversized model does not partially update an ai user or suggestion" do
    original_model = @ai_user.llm_model
    oversized_model = "m" * (Collavre::LlmModel::MAX_NAME_LENGTH + 1)

    assert_no_difference("Collavre::LlmModel.count") do
      patch update_ai_user_url(@ai_user), params: {
        user: { llm_vendor: "openai", llm_model: oversized_model }
      }
    end

    assert_response :unprocessable_entity
    assert_equal original_model, @ai_user.reload.llm_model
  end

  test "changing an ai user's vendor or model remembers the new selection" do
    assert_difference("Collavre::LlmModel.count", 1) do
      patch update_ai_user_url(@ai_user), params: {
        user: { llm_vendor: "anthropic", llm_model: "claude-sonnet-4" }
      }
    end

    assert Collavre::LlmModel.exists?(llm_vendor: "anthropic", name: "claude-sonnet-4")
  end

  test "ai user creation rolls back when remembering the model fails" do
    failure = ->(**) { raise "model suggestion failed" }

    Collavre::LlmModel.stub(:remember!, failure) do
      assert_no_difference([ "Collavre::User.count", "Collavre::Contact.count" ]) do
        assert_raises(RuntimeError, "model suggestion failed") do
          post create_ai_users_url, params: {
            ai_id: "rollback-model-bot",
            name: "Rollback Model Bot",
            llm_vendor: "openai",
            llm_model: "gpt-5.2"
          }
        end
      end
    end
  end

  test "ai user update rolls back when remembering the model fails" do
    original_vendor = @ai_user.llm_vendor
    original_model = @ai_user.llm_model
    failure = ->(**) { raise "model suggestion failed" }

    Collavre::LlmModel.stub(:remember!, failure) do
      assert_raises(RuntimeError, "model suggestion failed") do
        patch update_ai_user_url(@ai_user), params: {
          user: { llm_vendor: "openai", llm_model: "gpt-5.2" }
        }
      end
    end

    assert_equal original_vendor, @ai_user.reload.llm_vendor
    assert_equal original_model, @ai_user.llm_model
  end

  test "updating unrelated ai settings does not restore a deleted list entry" do
    model = Collavre::LlmModel.find_or_create_by!(llm_vendor: @ai_user.llm_vendor, name: @ai_user.llm_model)
    model.destroy!

    assert_no_difference("Collavre::LlmModel.count") do
      patch update_ai_user_url(@ai_user), params: { user: { name: "Renamed Agent" } }
    end

    refute Collavre::LlmModel.exists?(llm_vendor: @ai_user.llm_vendor, name: @ai_user.llm_model)
  end

  test "should preserve existing api key when submitted value is blank" do
    @ai_user.update!(llm_api_key: "existing-secret-key")

    patch update_ai_user_url(@ai_user), params: {
      user: { name: "Updated Bot Name", llm_api_key: "" }
    }

    assert_redirected_to user_path(@admin, tab: "contacts")
    assert_equal "existing-secret-key", @ai_user.reload.llm_api_key
  end

  test "should clear existing api key when explicitly requested" do
    @ai_user.update!(llm_api_key: "existing-secret-key")

    patch update_ai_user_url(@ai_user), params: {
      user: { llm_api_key: "", clear_llm_api_key: "1" }
    }

    assert_redirected_to user_path(@admin, tab: "contacts")
    assert_nil @ai_user.reload.llm_api_key
  end

  test "should preserve api key removal intent after validation failure" do
    @ai_user.update!(llm_api_key: "existing-secret-key")

    patch update_ai_user_url(@ai_user), params: {
      user: { name: "", llm_api_key: "", clear_llm_api_key: "1" }
    }

    assert_response :unprocessable_entity
    assert_select "input[type='checkbox'][name='user[clear_llm_api_key]'][checked='checked']"
    assert_equal "existing-secret-key", @ai_user.reload.llm_api_key
    assert_not_includes response.body, "existing-secret-key"
  end

  test "should update api key when submitted value is present" do
    @ai_user.update!(llm_api_key: "existing-secret-key")

    patch update_ai_user_url(@ai_user), params: {
      user: { llm_api_key: "replacement-secret-key" }
    }

    assert_redirected_to user_path(@admin, tab: "contacts")
    assert_equal "replacement-secret-key", @ai_user.reload.llm_api_key
  end

  test "should not update ai user if not authorized" do
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    patch update_ai_user_url(@ai_user), params: {
      user: {
        name: "Hacked Bot Name"
      }
    }

    assert_redirected_to user_path(other_user, tab: "contacts")
    assert_equal "You can only delete AI Users you created or be a system administrator.", flash[:alert]

    @ai_user.reload
    assert_not_equal "Hacked Bot Name", @ai_user.name
  end

  test "should save routing_expression with keyword trigger" do
    patch update_ai_user_url(@ai_user), params: {
      user: {
        routing_expression: 'chat.content contains "help"'
      }
    }
    assert_redirected_to user_path(@admin, tab: "contacts")
    @ai_user.reload
    assert_equal 'chat.content contains "help"', @ai_user.routing_expression
  end

  test "should save routing_expression with auto trigger" do
    patch update_ai_user_url(@ai_user), params: {
      user: {
        routing_expression: 'event_name == "comment_created"'
      }
    }
    assert_redirected_to user_path(@admin, tab: "contacts")
    @ai_user.reload
    assert_equal 'event_name == "comment_created"', @ai_user.routing_expression
  end

  test "should handle validation errors in update_ai" do
    patch update_ai_user_url(@ai_user), params: {
      user: {
        name: "" # Invalid name to trigger validation error
      }
    }
    assert_response :unprocessable_entity
    assert_equal "Name can't be blank", flash[:alert]
    assert_select "form[action=?]", update_ai_user_path(@ai_user)
  end
end
