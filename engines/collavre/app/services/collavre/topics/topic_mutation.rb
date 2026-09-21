# frozen_string_literal: true

module Collavre
  module Topics
    class TopicMutation
      def initialize(topic:, source_creative:)
        @topic = topic
        @source_creative = source_creative
      end

      def call
        Topic.transaction do
          topic.lock!
          unless topic.creative_id == source_creative.id
            raise TopicMove::SourceChangedError, I18n.t("collavre.topics.move.source_changed")
          end

          yield topic
        end
      end

      private

      attr_reader :topic, :source_creative
    end
  end
end
