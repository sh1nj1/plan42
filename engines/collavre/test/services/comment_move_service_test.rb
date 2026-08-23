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

    test "moves a retained legacy comment without a source topic" do
      destination = @creative.topics.create!(name: "Destination", user: @user)
      comment = Comment.create!(creative: @creative, user: @user, content: "legacy message")
      comment.update_column(:topic_id, nil)

      result = CommentMoveService.new(creative: @creative, user: @user).call(
        comment_ids: [ comment.id ], target_topic_id: destination.id
      )

      assert_equal 1, result[:moved_count]
      assert_equal @creative.id, comment.reload.creative_id
      assert_equal destination.id, comment.topic_id
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

    test "moving an unread comment honors an explicit zero source watermark" do
      source = @creative.topics.create!(name: "Source", user: @user)
      destination = @creative.topics.create!(name: "Destination", user: @user)
      moved = Comment.create!(creative: @creative, topic: source, user: users(:two), content: "unread source")
      legacy = Comment.create!(creative: @creative, user: users(:two), content: "legacy read")
      legacy.update_column(:topic_id, nil)
      read_destination = Comment.create!(creative: @creative, topic: destination, user: users(:two), content: "read destination")
      CommentReadPointer.create!(user: @user, creative: @creative, topic: source)
      CommentReadPointer.create!(user: @user, creative: @creative, last_read_comment_id: legacy.id)
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

    test "moving an unread comment to another creative does not let its Main pointer hide it" do
      destination_creative = Creative.create!(user: @user, description: "Destination")
      source_topic = @creative.topics.create!(name: "Source", user: @user)
      read_source = Comment.create!(creative: @creative, topic: source_topic, user: users(:two), content: "read source")
      moved = Comment.create!(creative: @creative, topic: source_topic, user: users(:two), content: "unread source")
      read_destination = Comment.create!(creative: destination_creative, user: users(:two), content: "read destination")
      CommentReadPointer.create!(user: @user, creative: @creative, topic: source_topic, last_read_comment_id: read_source.id)
      CommentReadPointer.create!(user: @user, creative: destination_creative, topic: destination_creative.main_topic, last_read_comment_id: read_destination.id)

      CommentMoveService.new(creative: @creative, user: @user).call(
        comment_ids: [ moved.id ], target_creative_id: destination_creative.id
      )

      pointer = CommentReadPointer.find_by!(user: @user, creative: destination_creative, topic: destination_creative.main_topic)
      assert_equal moved.id - 1, pointer.last_read_comment_id
      assert_operator Collavre::Creatives::CommentBadgeIndex.new(user: @user).unread_counts_by_topic(destination_creative)[destination_creative.main_topic.id], :>=, 1
    end

    test "rejects a stale existing-comment move after its source topic relocates" do
      destination_creative = Creative.create!(user: @user, description: "Destination")
      source_topic = @creative.topics.create!(name: "Source", user: @user)
      target_topic = @creative.topics.create!(name: "Target", user: @user)
      comment = Comment.create!(creative: @creative, topic: source_topic, user: @user, content: "move me")
      service = CommentMoveService.new(creative: @creative, user: @user)

      fetch_after_relocation = lambda do |_ids|
        Topics::TopicMove.new(topic: source_topic, target_creative: destination_creative).call
        [ comment ]
      end

      service.stub(:fetch_visible_comments, fetch_after_relocation) do
        assert_raises(CommentMoveService::MoveError) do
          service.call(comment_ids: [ comment.id ], target_topic_id: target_topic.id)
        end
      end

      assert_equal destination_creative.id, comment.reload.creative_id
      assert_equal source_topic.id, comment.topic_id
      assert_equal destination_creative.id, source_topic.reload.creative_id
      assert_equal @creative.id, target_topic.reload.creative_id
    end
  end
end
