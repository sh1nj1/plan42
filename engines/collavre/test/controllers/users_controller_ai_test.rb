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

  test "should save routing_expression with keyword trigger" do
    patch update_ai_user_url(@ai_user), params: {
      user: {
        routing_expression: 'chat.content contains "help"'
      }
    }
    assert_redirected_to edit_ai_user_path(@ai_user)
    @ai_user.reload
    assert_equal 'chat.content contains "help"', @ai_user.routing_expression
  end

  test "should save routing_expression with auto trigger" do
    patch update_ai_user_url(@ai_user), params: {
      user: {
        routing_expression: 'event_name == "comment_created"'
      }
    }
    assert_redirected_to edit_ai_user_path(@ai_user)
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

  # Regression: the edit form must pre-fill the prompt from the canonical
  # profile creative (data["markdown_source"]), not the legacy system_prompt
  # column. If the profile creative was edited directly, the column is stale;
  # rendering it would post it back and update_ai's sync would clobber the
  # profile-authored prompt on any unrelated setting change.
  test "edit_ai pre-fills the prompt from the canonical profile creative, not the stale column" do
    @ai_user.update_column(:system_prompt, "STALE COLUMN PROMPT")
    @ai_user.profile_creative.update!(content_type_input: "markdown", markdown_source: "CANONICAL EDITED PROMPT")

    get edit_ai_user_url(@ai_user)
    assert_response :success
    assert_select "textarea#user_system_prompt", text: /CANONICAL EDITED PROMPT/
    assert_select "textarea#user_system_prompt", text: /STALE COLUMN PROMPT/, count: 0
  end

  # Regression: with the form now posting the effective value, an unrelated
  # setting change (model) re-posts the canonical prompt and must not erase a
  # directly-edited profile prompt.
  test "update_ai preserves a directly-edited profile prompt when re-posting the effective value" do
    @ai_user.update_column(:system_prompt, "STALE COLUMN PROMPT")
    @ai_user.profile_creative.update!(content_type_input: "markdown", markdown_source: "CANONICAL EDITED PROMPT")

    patch update_ai_user_url(@ai_user), params: {
      user: {
        system_prompt: @ai_user.effective_system_prompt, # what the fixed form posts
        llm_model: "gemini-1.5-pro"
      }
    }
    assert_redirected_to edit_ai_user_path(@ai_user)
    @ai_user.reload
    assert_equal "gemini-1.5-pro", @ai_user.llm_model
    assert_equal "CANONICAL EDITED PROMPT", @ai_user.effective_system_prompt
    assert_equal "CANONICAL EDITED PROMPT", @ai_user.profile_creative.data["markdown_source"]
  end

  # Regression: a partial settings update that omits system_prompt entirely
  # (e.g. a routing_expression-only PATCH) must not run the prompt sync at all.
  # Otherwise the stale legacy column is copied back over the canonical
  # profile-authored prompt, silently erasing a directly-edited prompt.
  test "update_ai does not clobber the canonical prompt on a PATCH that omits system_prompt" do
    @ai_user.update_column(:system_prompt, "STALE COLUMN PROMPT")
    @ai_user.profile_creative.update!(content_type_input: "markdown", markdown_source: "CANONICAL EDITED PROMPT")

    patch update_ai_user_url(@ai_user), params: {
      user: {
        routing_expression: 'event_name == "comment_created"'
      }
    }
    assert_redirected_to edit_ai_user_path(@ai_user)
    @ai_user.reload
    assert_equal 'event_name == "comment_created"', @ai_user.routing_expression
    assert_equal "CANONICAL EDITED PROMPT", @ai_user.profile_creative.data["markdown_source"]
    assert_equal "CANONICAL EDITED PROMPT", @ai_user.effective_system_prompt
  end
end
