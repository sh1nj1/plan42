require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "convert comment to sub creative" do
    comment = @creative.comments.create!(content: "New idea", user: @user)
    assert_difference("Creative.count", 1) do
      assert_difference("Comment.count", -1) do
        post convert_creative_comment_path(@creative, comment)
      end
    end
    assert_response :no_content
    new_creative = @creative.children.last
    assert_equal "New idea", new_creative.description.to_plain_text.strip
  end
end
