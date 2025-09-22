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
      assert_no_difference("Comment.count") do
        post convert_creative_comment_path(@creative, comment)
      end
    end
    assert_response :no_content
    @creative.reload
    titles = @creative.children.order(:id).map { |c| c.description.to_plain_text.strip }
    assert_equal [ "First", "Second" ], titles

    system_comment = @creative.comments.order(:id).last
    assert_nil system_comment.user
    first_child = @creative.children.order(:id).first
    expected_title = first_child.description.to_plain_text.strip
    expected_message = I18n.t(
      "comments.convert_system_message",
      title: expected_title,
      url: creative_path(first_child)
    )
    assert_equal expected_message, system_comment.content
  end
end
