require "test_helper"

class UsersControllerAiTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @ai_user = users(:ai_bot)
    sign_in_as @admin, password: "password"
  end

  test "should get new_ai page with tools list" do
    get new_ai_users_url
    assert_response :success
    assert_select "h1", I18n.t("collavre.users.new_ai.title")
    assert_select "form[action=?]", create_ai_users_path
    # Verify tools section is rendered
    assert_select "label", I18n.t("collavre.users.edit_ai.tools_title")
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
    get edit_ai_user_url(@ai_user)
    assert_response :success
    assert_select "h1", "Edit AI Agent"
    assert_select "form[action=?]", update_ai_user_path(@ai_user)
  end

  test "should not get edit_ai for normal user" do
    get edit_ai_user_url(@admin)
    assert_redirected_to user_path(@admin)
    assert_equal "This user is not an AI agent.", flash[:alert]
  end

  test "should update ai user" do
    patch update_ai_user_url(@ai_user), params: {
      user: {
        name: "Updated Bot Name",
        system_prompt: "New prompt",
        llm_model: "gemini-1.5-pro",
        searchable: true
      }
    }
    assert_redirected_to edit_ai_user_path(@ai_user)
    @ai_user.reload
    assert_equal "Updated Bot Name", @ai_user.name
    assert_equal "New prompt", @ai_user.system_prompt
    assert_equal "gemini-1.5-pro", @ai_user.llm_model
    assert @ai_user.searchable
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
