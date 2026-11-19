# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class TopicDestroyTest < ActiveSupport::TestCase
      test "deleting a keep topic clears its loop and preserves other trigger settings" do
        source = creatives(:tshirt)
        topic = source.topics.create!(name: "Keep", user: users(:one))
        source.update!(data: { "trigger" => { "enabled" => true, "loop" => {
          "source" => "keep", "state" => "running", "trigger_topic_id" => topic.id
        } } })

        TopicDestroy.new(topic: topic, source_creative: source).call

        assert_nil source.reload.data.dig("trigger", "loop")
        assert_equal true, source.data.dig("trigger", "enabled")
        assert_not source.keep_loop?
      end

      test "deleting another topic preserves keep and drop loops" do
        source = creatives(:tshirt)
        %w[keep drop].each do |kind|
          topic = source.topics.create!(name: "Delete #{kind}", user: users(:one))
          config = { "source" => kind, "state" => "running", "trigger_topic_id" => kind == "keep" ? -1 : topic.id }
          source.update!(data: { "trigger" => { "loop" => config } })
          TopicDestroy.new(topic: topic, source_creative: source).call
          assert_equal config, source.reload.data.dig("trigger", "loop")
        end
      end

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
