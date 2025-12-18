require "test_helper"

class CommentReadPointersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
    @creative = creatives(:tshirt)
  end

  test "updating pointer marks inbox comment notifications as read" do
    commenter = users(:two)

    comment_one = Comment.create!(creative: @creative, user: commenter, content: "hi there")
    comment_two = Comment.create!(creative: @creative, user: commenter, content: "hello again")

    items = InboxItem.where(owner: @user, message_key: "inbox.comment_added").order(:created_at)
    assert_equal [ comment_one.id, comment_two.id ], items.map(&:comment_id)
    assert_equal %w[new new], items.pluck(:state)

    broadcasts = []
    body = nil

    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kwargs) {
      broadcasts << { stream: args.first, target: kwargs[:target], locals: kwargs[:locals] }
    }) do
      post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json
      body = JSON.parse(response.body)
    end

    assert_response :success
    assert_nil body["previous_last_read_comment_id"]
    assert_nil body["previous_effective_comment_id"]
    assert_nil body["previous_read_receipts_html"]
    assert_equal [ comment_two.id ], CommentReadPointer.where(user: @user, creative: @creative.effective_origin).pluck(:last_read_comment_id)
    assert_equal [ "read" ], InboxItem.where(id: items.pluck(:id)).pluck(:state).uniq
    assert broadcasts.any? { |payload| payload.dig(:locals, :count) == 0 }, "expected badge update broadcast with zero new items"
  end

  test "returns previous read pointer data without an existing badge" do
    commenter = users(:two)

    first_comment = Comment.create!(creative: @creative, user: commenter, content: "hi there")
    CommentReadPointer.create!(user: @user, creative: @creative, last_read_comment: first_comment)

    post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal first_comment.id, body["previous_last_read_comment_id"]
    assert_equal first_comment.id, body["previous_effective_comment_id"]
    assert_includes body["previous_read_receipts_html"], first_comment.id.to_s
  end
end
