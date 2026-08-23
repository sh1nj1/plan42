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
        reset_comment_counters
        unless current_topic&.creative_id == source_creative.id
          TopicsChannel.broadcast_to(source_creative, { action: "deleted", topic_id: topic.id })
        end
        return unless current_topic&.creative_id == target_creative.id

        TopicsChannel.broadcast_to(
          target_creative, { action: "created", topic: Serializer.call(current_topic) }
        )
      end

      private

      attr_reader :topic, :source_creative, :target_creative

      def reset_comment_counters
        [ source_creative, target_creative ].uniq(&:id).sort_by(&:id).each do |creative|
          Creative.reset_counters(creative.id, :comments)
        end
      end
    end
  end
end
