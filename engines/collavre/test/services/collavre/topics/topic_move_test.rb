# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class TopicMoveTest < ActiveSupport::TestCase
      test "locks the topic before relocating its comments" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        Comment.create!(creative: source, topic: topic, user: user, content: "message",
                        skip_default_user: true, skip_dispatch: true)

        calls = []
        comments = topic.comments
        original_update = comments.method(:update_all)
        lock_topic = -> { calls << :topic_lock }
        move_comments = lambda do |*arguments|
          calls << :comments_update
          original_update.call(*arguments)
        end

        topic.stub(:lock!, lock_topic) do
          topic.stub(:comments, comments) do
            comments.stub(:update_all, move_comments) do
              TopicMove.new(topic: topic, target_creative: destination).call
            end
          end
        end

        assert_equal %i[topic_lock comments_update], calls
      end

      test "rejects a move when the source changes before the lock is acquired" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        intervening = Creative.create!(description: "Intervening", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        comment = Comment.create!(creative: source, topic: topic, user: user, content: "message",
                                  skip_default_user: true, skip_dispatch: true)
        stale_move = TopicMove.new(topic: topic, target_creative: destination)

        TopicMove.new(topic: topic, target_creative: intervening).call

        error = assert_raises(TopicMove::SourceChangedError) do
          stale_move.call
        end

        assert_includes error.message, "moved"
        assert_equal intervening.id, topic.reload.creative_id
        assert_equal intervening.id, comment.reload.creative_id
      end

      test "runs validation after locking and before relocating comments" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        comment = Comment.create!(creative: source, topic: topic, user: user, content: "message",
                                  skip_default_user: true, skip_dispatch: true)

        error = assert_raises(ArgumentError) do
          TopicMove.new(topic: topic, target_creative: destination).call do |locked_topic|
            assert_equal topic, locked_topic
            raise ArgumentError, "rejected"
          end
        end

        assert_equal "rejected", error.message
        assert_equal source.id, topic.reload.creative_id
        assert_equal source.id, comment.reload.creative_id
      end

      test "moves comment snapshots with the topic" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        snapshot = CommentSnapshot.create!(
          creative: source, topic: topic, user: user, operation: "compress",
          comments_data: [
            { "id" => 1, "user_id" => user.id, "topic_id" => topic.id, "content" => "original" }
          ]
        )

        TopicMove.new(topic: topic, target_creative: destination).call
        restored = CommentSnapshotRestoreService.new(snapshot: snapshot, user: user).call

        assert_equal destination.id, snapshot.reload.creative_id
        assert_equal topic.id, snapshot.topic_id
        assert_equal destination.id, restored.first.creative_id
        assert_equal topic.id, restored.first.topic_id
      end

      test "rejects every active task status before relocating topic data" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)

        Task::ACTIVE_STATUSES.each do |status|
          topic = source.topics.create!(name: "Moving #{status}", user: user)
          comment = Comment.create!(creative: source, topic: topic, user: user, content: "message",
                                    skip_default_user: true, skip_dispatch: true)
          snapshot = CommentSnapshot.create!(
            creative: source, topic: topic, user: user, operation: "compress",
            comments_data: [ { "id" => comment.id, "topic_id" => topic.id, "content" => "message" } ]
          )
          Task.create!(name: status, agent: user, creative: source, topic_id: topic.id, status: status)

          error = assert_raises(TopicMove::ActiveTaskError) do
            TopicMove.new(topic: topic, target_creative: destination).call
          end

          assert_equal I18n.t("collavre.topics.move.active_tasks"), error.message
          assert_equal source.id, topic.reload.creative_id
          assert_equal source.id, comment.reload.creative_id
          assert_equal source.id, snapshot.reload.creative_id
        end
      end

      test "allows a topic with only terminal tasks to move" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)

        %w[done failed cancelled escalated].each do |status|
          Task.create!(name: status, agent: user, creative: source, topic_id: topic.id, status: status)
        end

        TopicMove.new(topic: topic, target_creative: destination).call

        assert_equal destination.id, topic.reload.creative_id
      end

      test "active task error is translated in English and Korean" do
        assert I18n.exists?("collavre.topics.move.active_tasks", :en)
        assert I18n.exists?("collavre.topics.move.active_tasks", :ko)
      end
    end
  end
end
