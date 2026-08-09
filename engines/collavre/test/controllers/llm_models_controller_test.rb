require "test_helper"

class LlmModelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two)
    sign_in_as @user, password: "password"
  end

  test "signed-in user can remove a model from the shared list" do
    model = Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5")
    agent = User.create!(
      email: "kept-model-agent@ai.local",
      password: "password",
      name: "Kept model agent",
      llm_vendor: model.llm_vendor,
      llm_model: model.name
    )

    assert_difference("Collavre::LlmModel.count", -1) do
      delete collavre.llm_model_path(model)
    end

    assert_response :no_content
    assert_equal "gpt-5", agent.reload.llm_model
  end

  test "signed-out user cannot remove a model" do
    model = Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5")
    sign_out

    assert_no_difference("Collavre::LlmModel.count") do
      delete collavre.llm_model_path(model)
    end

    assert_redirected_to collavre.new_session_path
  end
end
