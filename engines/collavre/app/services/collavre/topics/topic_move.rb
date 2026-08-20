# frozen_string_literal: true

module Collavre
  module Topics
    class TopicMove
      class SourceChangedError < StandardError; end

      def initialize(topic:, target_creative:)
        @topic = topic
        @target_creative = target_creative
        @source_creative_id = topic.creative_id
      end

      def call
        Topic.transaction do
          # TopicBranchService locks the source before reading its comments.
          # Take the same parent-first lock order here so a branch cannot
          # authorize the old creative while this transaction has already
          # relocated the topic's comment rows to the new one.
          topic.lock!
          reject_changed_source!
          topic.comments.update_all(creative_id: target_creative.id)
          ReadPointerRelocator.new(topic: topic, target_creative: target_creative).call
          topic.update!(creative: target_creative)
          release_unroutable_primary_agent
        end
      end

      private

      attr_reader :topic, :target_creative, :source_creative_id

      def reject_changed_source!
        return if topic.creative_id == source_creative_id

        raise SourceChangedError, I18n.t("collavre.topics.move.source_changed")
      end

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
