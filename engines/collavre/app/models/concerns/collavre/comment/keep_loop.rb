# frozen_string_literal: true

module Collavre
  class Comment
    module KeepLoop
      extend ActiveSupport::Concern

      included do
        attr_accessor :keep_loop_options
        after_create :initialize_keep_loop
      end

      private

      def post_loop_resume(iteration, max)
        return unless creative.trigger_loop_enabled?

        agent = creative.trigger_loop_agent
        return unless agent || creative.keep_loop?

        creative.comments.create!(
          content: "#{"@#{agent.name}: " if agent}#{I18n.t(
            'collavre.trigger_loop.user_resumed',
            iteration: iteration,
            max: max
          )}",
          topic_id: topic_id,
          private: false,
          user: creative.user,
          skip_dispatch: false
        )
      end

      def initialize_keep_loop
        return unless keep_loop_options

        applied = Comments::TopicMutation.call(topic_id, creative_id) { persist_keep_loop }
        return if applied

        errors.add(:topic, I18n.t("collavre.comments.invalid_topic"))
        raise ActiveRecord::RecordInvalid, self
      end

      def persist_keep_loop
        creative.with_lock do
          data = (creative.data || {}).deep_dup
          data["trigger"] ||= {}
          data["trigger"]["loop"] = TriggerLoopConfig.build(topic_id, source: "keep", start_comment_id: id, **keep_loop_options)
          creative.update!(data: data)
        end
      end
    end
  end
end
