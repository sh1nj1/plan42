require "test_helper"

class CreativePromptTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "prompt@example.com", password: "pw", name: "User")
    @creative = Creative.create!(user: @user, description: "Slide")
    sign_in_as(@user)
  end

  test "returns prompt in JSON response" do
    @creative.comments.create!(user: @user, content: "> Hello presenter", private: true)

    get creative_path(@creative, format: :json)
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal "Hello presenter", data["prompt"]
  end
end
