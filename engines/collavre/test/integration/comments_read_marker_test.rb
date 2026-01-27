require "test_helper"

class CommentsReadMarkerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "marker@example.com", password: TEST_PASSWORD, name: "Marker")
    @creative = Creative.create!(user: @user, description: "Some creative")
    sign_in_as(@user)
  end

  test "does not show last-read bar when pointer at latest comment" do
    @creative.comments.create!(user: @user, content: "First")
    last = @creative.comments.create!(user: @user, content: "Second")
    CommentReadPointer.create!(user: @user, creative: @creative, last_read_comment: last)

    get creative_comments_path(@creative)
    assert_response :success
    refute_includes response.body, "last-read"
  end
end
