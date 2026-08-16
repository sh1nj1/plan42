# frozen_string_literal: true

module Collavre
  module Topics
    class TopicMove
      def initialize(topic:, target_creative:)
        @topic = topic
        @target_creative = target_creative
      end

      def call
        Topic.transaction do
          topic.comments.update_all(creative_id: target_creative.id)
          ReadPointerRelocator.new(topic: topic, target_creative: target_creative).call
          topic.update!(creative: target_creative)
          release_unroutable_primary_agent
        end
      end

      private

      attr_reader :topic, :target_creative

      def release_unroutable_primary_agent
        agent = topic.primary_agent
        rejection = agent && Topic.primary_agent_rejection(target_creative, agent, topic: topic)
        return [ nil, nil ] unless rejection

        topic.set_primary_agent!(nil)
        [ agent, rejection ]
      end
    end
  end
end
