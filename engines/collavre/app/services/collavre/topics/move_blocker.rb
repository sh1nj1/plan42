# frozen_string_literal: true

module Collavre
  module Topics
    class MoveBlocker
      class ActiveTaskError < StandardError; end
      class RecurringTaskError < StandardError; end

      def initialize(topic)
        @topic = topic
      end

      def call
        if Task.where(topic_id: topic.id, status: Task::ACTIVE_STATUSES).exists?
          raise ActiveTaskError, I18n.t("collavre.topics.move.active_tasks")
        end
        return unless Crons::RecurringTopicTasks.new(topic.id).any?

        raise RecurringTaskError, I18n.t("collavre.topics.move.recurring_tasks")
      end

      private

      attr_reader :topic
    end
  end
end
