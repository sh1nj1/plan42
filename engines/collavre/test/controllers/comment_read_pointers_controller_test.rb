require "test_helper"

class CommentReadPointersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
    @creative = creatives(:tshirt)
  end

  test "updating pointer sets last_read_comment_id" do
    commenter = users(:two)

    comment_one = Comment.create!(creative: @creative, user: commenter, content: "hi there")
    comment_two = Comment.create!(creative: @creative, user: commenter, content: "hello again")

    post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json

    assert_response :success
    pointer = CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin)
    assert_equal comment_two.id, pointer.last_read_comment_id
  end

  test "updating pointer broadcasts badge update" do
    commenter = users(:two)
    Comment.create!(creative: @creative, user: commenter, content: "hi there")

    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kwargs) {
      broadcasts << { stream: args.first, target: kwargs[:target], locals: kwargs[:locals] }
    }) do
      post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json
    end

    assert_response :success
    assert broadcasts.any? { |payload| payload.dig(:locals, :count) == 0 }, "expected badge update broadcast with zero unread"
  end
end
