# frozen_string_literal: true

module Collavre
  module Topics
    class TopicMoveEffects
      def initialize(topic, source_creative, target_creative)
        @topic = topic
        @source_creative = source_creative
        @target_creative = target_creative
      end

      def call(current_topic)
        Creative.reset_counters(source_creative.id, :comments)
        Creative.reset_counters(target_creative.id, :comments)
        TopicsChannel.broadcast_to(source_creative, { action: "deleted", topic_id: topic.id })
        return unless current_topic&.creative_id == target_creative.id

        TopicsChannel.broadcast_to(
          target_creative, { action: "created", topic: Serializer.call(current_topic) }
        )
      end

      private

      attr_reader :topic, :source_creative, :target_creative
    end
  end
end
