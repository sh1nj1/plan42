require "test_helper"

class CommentsControllerSecurityTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @other_creative = creatives(:root_parent)
    @topic = Topic.create!(name: "Other Topic", creative: @other_creative, user: @user)

    sign_in_as(@user, password: "password")
  end

  test "should not allow creating comment with topic from another creative" do
    assert_no_difference("Comment.count") do
      post creative_comments_url(@creative), params: {
        comment: {
          content: "Malicious comment",
          topic_id: @topic.id
        }
      }, xhr: true
    end

    assert_response :unprocessable_entity
  end

  test "should infer topic from around_comment_id and return comment" do
    # Create a comment in the "Other Topic"
    comment = @other_creative.comments.create!(
      content: "Topic Comment",
      user: @user,
      topic: @topic
    )

    # Request index with around_comment_id pointing to this comment, NO topic_id
    get creative_comments_url(@other_creative), params: {
      around_comment_id: comment.id
    }, xhr: true

    assert_response :success

    # Verify X-Topic-Id header
    assert_equal @topic.id.to_s, response.headers["X-Topic-Id"]

    # Verify comment is in the response body (partial rendering)
    assert_includes response.body, "Topic Comment"
  end

  test "should not allow updating comment with topic from another creative" do
    comment = @creative.comments.create!(content: "Original Topic", user: @user)

    put creative_comment_url(@creative, comment), params: {
      comment: {
        topic_id: @topic.id # @topic belongs to @other_creative
      }
    }, xhr: true

    assert_response :unprocessable_entity
    assert_equal I18n.t("collavre.comments.invalid_topic"), JSON.parse(response.body)["error"]
  end
end
