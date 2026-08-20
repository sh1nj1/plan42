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
    end
  end
end
