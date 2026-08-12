require "test_helper"

module Collavre
  class CommentMoveServiceTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      Current.user = @user
    end

    teardown do
      Current.user = nil
    end

    test "raises error when no comment_ids provided" do
      service = CommentMoveService.new(creative: @creative, user: @user)
      error = assert_raises(CommentMoveService::MoveError) do
        service.call(comment_ids: [])
      end
      assert_equal I18n.t("collavre.comments.move_no_selection"), error.message
    end

    test "raises error when target is invalid" do
      service = CommentMoveService.new(creative: @creative, user: @user)
      error = assert_raises(CommentMoveService::MoveError) do
        service.call(comment_ids: [ 1 ])
      end
      assert_equal I18n.t("collavre.comments.move_invalid_target"), error.message
    end

    test "raises error when target creative does not exist" do
      service = CommentMoveService.new(creative: @creative, user: @user)
      error = assert_raises(CommentMoveService::MoveError) do
        service.call(comment_ids: [ 1 ], target_creative_id: -999)
      end
      assert_equal I18n.t("collavre.comments.move_invalid_target"), error.message
    end
    test "moving to Main stores the real Main topic" do
      topic = @creative.topics.create!(name: "Source", user: @user)
      comment = Comment.create!(creative: @creative, topic: topic, user: @user, content: "move me")

      CommentMoveService.new(creative: @creative, user: @user).call(comment_ids: [ comment.id ], target_topic_id: "")

      assert_equal @creative.main_topic.id, comment.reload.topic_id
    end

    test "moving an unread comment does not let the destination pointer hide it" do
      source = @creative.topics.create!(name: "Source", user: @user)
      destination = @creative.topics.create!(name: "Destination", user: @user)
      read_source = Comment.create!(creative: @creative, topic: source, user: users(:two), content: "read source")
      moved = Comment.create!(creative: @creative, topic: source, user: users(:two), content: "unread source")
      read_destination = Comment.create!(creative: @creative, topic: destination, user: users(:two), content: "read destination")
      CommentReadPointer.create!(user: @user, creative: @creative, topic: source, last_read_comment_id: read_source.id)
      CommentReadPointer.create!(user: @user, creative: @creative, topic: destination, last_read_comment_id: read_destination.id)

      CommentMoveService.new(creative: @creative, user: @user).call(comment_ids: [ moved.id ], target_topic_id: destination.id)

      pointer = CommentReadPointer.find_by!(user: @user, creative: @creative, topic: destination)
      assert_equal moved.id - 1, pointer.last_read_comment_id
      assert_operator Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(@creative)[destination.id], :>=, 1
    end

    test "moving a private comment does not rewind a pointer for a user who cannot view it" do
      source = @creative.topics.create!(name: "Source", user: @user)
      destination = @creative.topics.create!(name: "Destination", user: @user)
      other_user = users(:three)
      source_before = Comment.create!(creative: @creative, topic: source, user: users(:two), content: "source before")
      moved = Comment.create!(creative: @creative, topic: source, user: users(:two), approver: @user, private: true, content: "private unread")
      read_destination = Comment.create!(creative: @creative, topic: destination, user: users(:two), content: "read destination")
      CommentReadPointer.create!(user: other_user, creative: @creative, topic: source, last_read_comment_id: source_before.id)
      destination_pointer = CommentReadPointer.create!(user: other_user, creative: @creative, topic: destination, last_read_comment_id: read_destination.id)

      CommentMoveService.new(creative: @creative, user: @user).call(comment_ids: [ moved.id ], target_topic_id: destination.id)

      assert_equal read_destination.id, destination_pointer.reload.last_read_comment_id
    end
  end
end
