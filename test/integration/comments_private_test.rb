require "test_helper"

class CommentsPrivateTest < ActionDispatch::IntegrationTest
  setup do
    @user1 = User.create!(email: "user1@example.com", password: TEST_PASSWORD, name: "User1")
    @user2 = User.create!(email: "user2@example.com", password: TEST_PASSWORD, name: "User2")
    @creative = Creative.create!(user: @user1, description: "Some creative")
    @creative.comments.create!(user: @user1, content: "public")
    @creative.comments.create!(user: @user1, content: "secret", private: true)
  end

  test "private comments only visible to author" do
    sign_in_as(@user1)
    get creative_comments_path(@creative)
    assert_response :success
    assert_includes response.body, "public"
    assert_includes response.body, "secret"

    sign_out
    sign_in_as(@user2)
    get creative_comments_path(@creative)
    assert_response :success
    assert_includes response.body, "public"
    refute_includes response.body, "secret"
  end
end
