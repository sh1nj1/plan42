# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class TopicDestroyTest < ActiveSupport::TestCase
      test "rejects deletion when the topic moved before its lock" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        destroy = TopicDestroy.new(topic: topic, source_creative: source)

        TopicMove.new(topic: topic, target_creative: destination).call

        error = assert_raises(TopicMove::SourceChangedError) { destroy.call }

        assert_equal I18n.t("collavre.topics.move.source_changed"), error.message
        assert_equal destination.id, topic.reload.creative_id
      end

      test "locks the topic before destroying it" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        topic = source.topics.create!(name: "Delete", user: user)
        calls = []
        lock_topic = -> { calls << :topic_lock }
        destroy_topic = -> { calls << :destroy; true }

        topic.stub(:lock!, lock_topic) do
          topic.stub(:destroy!, destroy_topic) do
            TopicDestroy.new(topic: topic, source_creative: source).call
          end
        end

        assert_equal %i[topic_lock destroy], calls
      end
    end
  end
end
