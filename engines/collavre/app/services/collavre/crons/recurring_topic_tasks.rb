# frozen_string_literal: true

module Collavre
  module Crons
    class RecurringTopicTasks
      include RecurringTaskArguments

      def initialize(topic_id)
        @topic_id = topic_id.to_i
      end

      def any?
        SolidQueue::RecurringTask.where(static: false).any? do |task|
          parse_arguments(task)["topic_id"].to_i == topic_id
        end
      end

      private

      attr_reader :topic_id
    end
  end
end
