require "test_helper"

class CreativePromptTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "prompt@example.com", password: TEST_PASSWORD, name: "User")
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

  test "returns raw and embedded description variants in JSON response" do
    youtube_link = '<a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">watch</a>'
    @creative.update!(description: youtube_link)

    get creative_path(@creative, format: :json)
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal youtube_link, data["description"]
    assert_includes data["description_embedded_html"], "<iframe"
    assert_includes data["description_embedded_html"], "youtube.com/embed/dQw4w9WgXcQ"
  end
end
