require "test_helper"

class CreativeImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "import@example.com", password: TEST_PASSWORD, name: "Importer", email_verified_at: Time.current)
    sign_in_as(@user)
  end

  test "imports markdown files" do
    file = fixture_file_upload("sample.md", "text/markdown")

    before_count = Creative.count
    post collavre.creative_imports_path, params: { markdown: file }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert json["created"].present?
    assert_operator Creative.count, :>, before_count
  end

  test "rejects unsupported file types" do
    file = fixture_file_upload("invalid.txt", "text/plain")

    assert_no_difference("Creative.count") do
      post collavre.creative_imports_path, params: { markdown: file }
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Invalid file type", json["error"]
  end

  test "returns unauthorized when user not signed in" do
    delete session_path

    post collavre.creative_imports_path, params: { markdown: fixture_file_upload("sample.md", "text/markdown") }

    assert_response :unauthorized
  end
end
