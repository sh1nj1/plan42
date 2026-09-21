# frozen_string_literal: true

module Collavre
  module Topics
    class TopicDestroy
      def initialize(topic:, source_creative:)
        @topic = topic
        @source_creative = source_creative
      end

      def call
        Topic.transaction do
          topic.lock!
          reject_changed_source!
          [ topic.id, topic.name ].tap { topic.destroy! }
        end
      end

      private

      attr_reader :topic, :source_creative

      def reject_changed_source!
        return if topic.creative_id == source_creative.id

        raise TopicMove::SourceChangedError, I18n.t("collavre.topics.move.source_changed")
      end
    end
  end
end
