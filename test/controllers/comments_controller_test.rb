require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "convert markdown comment to sub creatives" do
    comment = @creative.comments.create!(content: "- First\n- Second", user: @user)
    assert_difference("Creative.count", 2) do
      assert_difference("Comment.count", -1) do
        post convert_creative_comment_path(@creative, comment)
      end
    end
    assert_response :no_content
    titles = @creative.children.order(:id).map { |c| c.description.to_plain_text.strip }
    assert_equal [ "First", "Second" ], titles
  end
end
