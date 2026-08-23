# frozen_string_literal: true

module Collavre
  module Topics
    class MoveBlocker
      class MoveBlockedError < StandardError; end
      class ActiveTaskError < MoveBlockedError; end
      class RecurringTaskError < MoveBlockedError; end
      class TriggerLoopError < MoveBlockedError; end

      def initialize(topic)
        @topic = topic
      end

      def call
        if Task.where(topic_id: topic.id, status: Task::ACTIVE_STATUSES).exists?
          raise ActiveTaskError, I18n.t("collavre.topics.move.active_tasks")
        end
        if trigger_loop_topic?
          raise TriggerLoopError, I18n.t("collavre.topics.move.trigger_loop")
        end
        return unless Crons::RecurringTopicTasks.new(topic.id).any?

        raise RecurringTaskError, I18n.t("collavre.topics.move.recurring_tasks")
      end

      private

      attr_reader :topic

      def trigger_loop_topic?
        creative_data = Creative.where(id: topic.creative_id).pick(:data)
        creative_data&.dig("trigger", "loop", "trigger_topic_id").to_i == topic.id
      end
    end
  end
end
