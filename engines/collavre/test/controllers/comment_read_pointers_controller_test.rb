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

  test "updating a topic only marks that topic as read" do
    first_topic = @creative.main_topic
    second_topic = @creative.topics.create!(name: "Second", user: @user)
    Comment.create!(creative: @creative, topic: first_topic, user: users(:two), content: "first")
    unread = Comment.create!(creative: @creative, topic: second_topic, user: users(:two), content: "second")

    post "/comment_read_pointers/update", params: { creative_id: @creative.id, topic_id: first_topic.id }, as: :json

    assert_response :success
    pointer = CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: first_topic)
    assert_equal first_topic.comments.maximum(:id), pointer.last_read_comment_id
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: second_topic)

    counts = Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative)
    assert_equal({ second_topic.id => 1 }, counts)
    assert_equal unread.id, second_topic.comments.maximum(:id)
  end

  test "All Messages leaves archived topic comments unread" do
    active_topic = @creative.topics.create!(name: "Active", user: @user)
    archived_topic = @creative.topics.create!(name: "Archived", user: @user, archived_at: Time.current)
    archived = Comment.create!(creative: @creative, topic: archived_topic, user: users(:two), content: "archived")
    Comment.create!(creative: @creative, topic: active_topic, user: users(:two), content: "active")

    post "/comment_read_pointers/update", params: { creative_id: @creative.id }, as: :json

    assert_response :success
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative.effective_origin, topic: archived_topic)
    counts = Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative)
    assert_equal({ archived_topic.id => 1 }, counts)
    assert_equal archived.id, archived_topic.comments.maximum(:id)
  end

  test "rejects a topic from another creative" do
    foreign_topic = Creative.create!(user: @user, description: "Foreign").main_topic

    post "/comment_read_pointers/update", params: { creative_id: @creative.id, topic_id: foreign_topic.id }, as: :json

    assert_response :unprocessable_entity
    assert_nil CommentReadPointer.find_by(user: @user, creative: @creative)
  end
end
