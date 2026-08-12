require "test_helper"
require Rails.root.join(
  "engines/collavre/db/migrate/20260812000001_add_topic_to_comment_read_pointers"
)

class AddTopicToCommentReadPointersTest < ActiveSupport::TestCase
  test "rollback preserves unread topics by using the lowest topic watermark" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Rollback read pointers", sequence: 920)
    main_topic = creative.main_topic
    first_topic = creative.topics.create!(name: "First", user: user)
    second_topic = creative.topics.create!(name: "Second", user: user)
    first_comment = Comment.create!(creative: creative, topic: first_topic, user: users(:two), content: "first")
    latest_comment = Comment.create!(creative: creative, topic: second_topic, user: users(:two), content: "latest")
    legacy_pointer = CommentReadPointer.create!(user: user, creative: creative, last_read_comment_id: first_comment.id)
    CommentReadPointer.create!(user: user, creative: creative, topic: main_topic, last_read_comment_id: first_comment.id)
    CommentReadPointer.create!(user: user, creative: creative, topic: first_topic, last_read_comment_id: first_comment.id)
    CommentReadPointer.create!(user: user, creative: creative, topic: second_topic, last_read_comment_id: latest_comment.id)

    AddTopicToCommentReadPointers.new.send(:consolidate_topic_watermarks)

    assert_equal first_comment.id, legacy_pointer.reload.last_read_comment_id
  end

  test "rollback creates a legacy pointer when only topic pointers exist" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Topic-only rollback pointers", sequence: 921)
    main_topic = creative.main_topic
    first_topic = creative.topics.create!(name: "First", user: user)
    second_topic = creative.topics.create!(name: "Second", user: user)
    first_comment = Comment.create!(creative: creative, topic: first_topic, user: users(:two), content: "first")
    latest_comment = Comment.create!(creative: creative, topic: second_topic, user: users(:two), content: "latest")
    CommentReadPointer.create!(user: user, creative: creative, topic: main_topic, last_read_comment_id: first_comment.id)
    CommentReadPointer.create!(user: user, creative: creative, topic: first_topic, last_read_comment_id: first_comment.id)
    CommentReadPointer.create!(user: user, creative: creative, topic: second_topic, last_read_comment_id: latest_comment.id)

    AddTopicToCommentReadPointers.new.send(:consolidate_topic_watermarks)

    legacy_pointer = CommentReadPointer.find_by!(user: user, creative: creative, topic: nil)
    assert_equal first_comment.id, legacy_pointer.last_read_comment_id
  end

  test "rollback treats topics without pointers as unread" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Missing topic rollback pointer", sequence: 922)
    first_topic = creative.topics.create!(name: "First", user: user)
    second_topic = creative.topics.create!(name: "Second", user: user)
    first_comment = Comment.create!(creative: creative, topic: first_topic, user: users(:two), content: "first")
    Comment.create!(creative: creative, topic: second_topic, user: users(:two), content: "unread")
    CommentReadPointer.create!(user: user, creative: creative, topic: first_topic, last_read_comment_id: first_comment.id)

    AddTopicToCommentReadPointers.new.send(:consolidate_topic_watermarks)

    legacy_pointer = CommentReadPointer.find_by!(user: user, creative: creative, topic: nil)
    assert_equal 0, legacy_pointer.last_read_comment_id
  end
end
