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
    end
  end
end
